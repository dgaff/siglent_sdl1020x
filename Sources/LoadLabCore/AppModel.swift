import Foundation
import Observation
import SCPIKit
import SDLKit

/// A saved or discovered instrument shown in the sidebar.
public struct KnownDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(host):\(port)" }
    public var host: String
    public var port: UInt16
    public var model: String?
    public var serial: String?
    public var lastSeen: Date?
    public var busy = false

    public init(host: String, port: UInt16 = 5025, model: String? = nil, serial: String? = nil) {
        self.host = host; self.port = port; self.model = model; self.serial = serial
    }

    public var title: String { model ?? host }
    public var subtitle: String { model == nil ? "\(host)" : "\(host)\(serial.map { " · \($0)" } ?? "")" }
}

/// Top-level app state: known devices, discovery, the active session, navigation.
@MainActor @Observable
public final class AppModel {
    public var devices: [KnownDevice] = []
    public private(set) var scanning = false
    public var session: DeviceSession?
    public var selectedFunction: ActiveFunction = .basic
    /// The run library replaces the function pane when shown (works without a connection).
    public var showingLibrary = false
    public let library = LibraryModel()

    private let defaults: UserDefaults
    private static let recentsKey = "recentDevices"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.recentsKey),
           let saved = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            devices = saved.map { var d = $0; d.busy = false; return d }
        }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(devices) { defaults.set(data, forKey: Self.recentsKey) }
    }

    /// Sweeps the local network. SDL1000X units are kept; other instruments are ignored.
    /// A busy host is kept only if it was already known (we can't identify it).
    public func scan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let found = await Discovery.sweep()
        for d in found {
            if let id = d.identity {
                guard id.isSDL1000X else { continue }
                upsert(host: d.host, port: d.port, model: id.model, serial: id.serial, busy: false)
            } else if let i = devices.firstIndex(where: { $0.host == d.host && $0.port == d.port }) {
                // Busy: someone (maybe us) holds the connection.
                let ours = session?.host == d.host && session?.link.isUsable == true
                devices[i].busy = !ours
            }
        }
        saveRecents()
    }

    public func upsert(host: String, port: UInt16 = 5025, model: String? = nil, serial: String? = nil, busy: Bool = false) {
        if let i = devices.firstIndex(where: { $0.host == host && $0.port == port }) {
            if let model { devices[i].model = model }
            if let serial { devices[i].serial = serial }
            devices[i].lastSeen = Date()
            devices[i].busy = busy
        } else {
            var d = KnownDevice(host: host, port: port, model: model, serial: serial)
            d.lastSeen = Date(); d.busy = busy
            devices.append(d)
        }
        saveRecents()
    }

    public func remove(_ d: KnownDevice) {
        devices.removeAll { $0.id == d.id }
        saveRecents()
    }

    /// Connects to `device`, closing any existing session first.
    public func connect(_ device: KnownDevice) async {
        if let s = session { await s.disconnect() }
        let s = DeviceSession(host: device.host, port: device.port)
        session = s
        await s.connect()
        await s.resumeInterruptedRuns()
        if let id = s.identity {
            upsert(host: device.host, port: device.port, model: id.model, serial: id.serial)
        }
        selectedFunction = s.recorder != nil ? .battery : s.state.function
        showingLibrary = false
    }

    public func disconnect() async {
        await session?.disconnect()
        session = nil
    }
}
