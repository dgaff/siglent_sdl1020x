import Foundation
import Network

public struct DiscoveredInstrument: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable { case sweep, mdns, manual }
    public var id: String { "\(host):\(port)" }
    public let host: String
    public let port: UInt16
    /// nil when the instrument is busy (it accepted the TCP connection, then closed it
    /// without replying: the SDL1000X allows only one client at a time).
    public let identity: InstrumentIdentity?
    public let source: Source
    public var isBusy: Bool { identity == nil }

    public init(host: String, port: UInt16, identity: InstrumentIdentity?, source: Source) {
        self.host = host; self.port = port; self.identity = identity; self.source = source
    }
}

public enum ProbeResult: Sendable, Equatable {
    case identified(InstrumentIdentity)
    /// Port open, but the peer closed the connection without answering (single-client
    /// instruments that already have a controller attached).
    case busy
    case nothing
}

/// Finds SCPI instruments on the local network.
///
/// The SDL1000X does not advertise via mDNS and ignores VXI-11 UDP broadcasts, so the primary
/// mechanism is a parallel TCP connect sweep of port 5025 across each local IPv4 subnet,
/// followed by `*IDN?`. mDNS (`_scpi-raw._tcp`) is browsed in parallel to pick up instruments
/// that do advertise (e.g. Keysight supplies).
public enum Discovery {
    public struct Subnet: Sendable, Hashable, CustomStringConvertible {
        public let interface: String
        public let address: UInt32   // host byte order
        public let netmask: UInt32
        public var prefixLength: Int { netmask.nonzeroBitCount }
        public var description: String { "\(interface) \(ipString(address))/\(prefixLength)" }

        /// All usable host addresses except our own.
        public var hosts: [String] {
            let network = address & netmask
            let broadcast = network | ~netmask
            guard broadcast > network + 1 else { return [] }
            return (network + 1 ..< broadcast).filter { $0 != address }.map(ipString)
        }
    }

    /// Local IPv4 subnets suitable for sweeping (up, non-loopback, prefix >= /22).
    public static func localSubnets(minPrefix: Int = 22) -> [Subnet] {
        var result: [Subnet] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let s = Subnet(interface: String(cString: ifa.ifa_name), address: a, netmask: m)
            guard s.prefixLength >= minPrefix, s.prefixLength < 31 else { continue }
            // Skip link-local 169.254/16.
            guard a >> 16 != 0xA9FE else { continue }
            result.append(s)
        }
        return result
    }

    /// Probes one host: TCP connect, `*IDN?`, disconnect.
    public static func probe(host: String, port: UInt16 = 5025,
                             connectTimeout: Duration = .milliseconds(500),
                             replyTimeout: Duration = .milliseconds(1500)) async -> ProbeResult {
        let conn = SCPIConnection(host: host, port: port, timeout: replyTimeout)
        do {
            try await conn.connect(timeout: connectTimeout)
        } catch {
            await conn.disconnect()
            return .nothing
        }
        let result: ProbeResult
        do {
            let idn = try await conn.query("*IDN?")
            result = InstrumentIdentity(idn: idn).map(ProbeResult.identified) ?? .nothing
        } catch SCPIError.connectionClosed {
            result = .busy
        } catch SCPIError.notConnected {
            result = .busy      // closed before we could even send
        } catch {
            result = .nothing
        }
        // Release promptly: single-client instruments stay blocked until we close.
        await conn.disconnect()
        return result
    }

    /// Convenience: identity only.
    public static func identify(host: String, port: UInt16 = 5025) async -> InstrumentIdentity? {
        if case .identified(let id) = await probe(host: host, port: port) { return id }
        return nil
    }

    /// Sweeps the given hosts (default: all local subnets) with bounded concurrency.
    /// `onFound` is called as each instrument is identified.
    public static func sweep(hosts: [String]? = nil, port: UInt16 = 5025, concurrency: Int = 128,
                             onFound: (@Sendable (DiscoveredInstrument) -> Void)? = nil) async -> [DiscoveredInstrument] {
        let targets = hosts ?? localSubnets().flatMap(\.hosts)
        var found: [DiscoveredInstrument] = []
        await withTaskGroup(of: DiscoveredInstrument?.self) { group in
            var it = targets.makeIterator()
            func addNext() -> Bool {
                guard let h = it.next() else { return false }
                group.addTask {
                    let d: DiscoveredInstrument
                    switch await probe(host: h, port: port) {
                    case .identified(let id): d = DiscoveredInstrument(host: h, port: port, identity: id, source: .sweep)
                    case .busy: d = DiscoveredInstrument(host: h, port: port, identity: nil, source: .sweep)
                    case .nothing: return nil
                    }
                    onFound?(d)
                    return d
                }
                return true
            }
            for _ in 0..<concurrency { if !addNext() { break } }
            while let r = await group.next() {
                if let r { found.append(r) }
                _ = addNext()
            }
        }
        return found.sorted { ipSortKey($0.host) < ipSortKey($1.host) }
    }

    /// Browses mDNS for `_scpi-raw._tcp` for `duration`, resolving and identifying each service.
    public static func browseMDNS(duration: Duration = .seconds(2)) async -> [DiscoveredInstrument] {
        let browser = NWBrowser(for: .bonjour(type: "_scpi-raw._tcp", domain: nil), using: .tcp)
        let results = LockedBox<Set<NWBrowser.Result>>([])
        browser.browseResultsChangedHandler = { r, _ in results.set(r) }
        browser.start(queue: .global())
        try? await Task.sleep(for: duration)
        browser.cancel()
        var out: [DiscoveredInstrument] = []
        for r in results.get() {
            guard case .service = r.endpoint else { continue }
            // Resolve by connecting to the service endpoint and reading the resolved IP.
            if let (host, port) = await resolve(r.endpoint),
               let id = await identify(host: host, port: port) {
                out.append(DiscoveredInstrument(host: host, port: port, identity: id, source: .mdns))
            }
        }
        return out
    }

    private static func resolve(_ endpoint: NWEndpoint) async -> (String, UInt16)? {
        let conn = NWConnection(to: endpoint, using: .tcp)
        let box = LockedBox<(String, UInt16)?>(nil)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = LockedBox(false)
            @Sendable func finish() { if !once.swap(true) { cont.resume() } }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(h, p) = conn.currentPath?.remoteEndpoint {
                        var hs = "\(h)"
                        if let pct = hs.firstIndex(of: "%") { hs = String(hs[..<pct]) }
                        box.set((hs, p.rawValue))
                    }
                    finish()
                case .failed, .cancelled, .waiting: finish()
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish() }
        }
        conn.cancel()
        return box.get()
    }

    /// Full discovery: subnet sweep + mDNS, de-duplicated by host.
    public static func discoverAll(onFound: (@Sendable (DiscoveredInstrument) -> Void)? = nil) async -> [DiscoveredInstrument] {
        async let swept = sweep(onFound: onFound)
        async let mdns = browseMDNS()
        var byHost: [String: DiscoveredInstrument] = [:]
        for d in await mdns { byHost[d.host] = d }
        for d in await swept { byHost[d.host] = d }   // prefer sweep entries (plain IPs)
        return byHost.values.sorted { ipSortKey($0.host) < ipSortKey($1.host) }
    }
}

func ipString(_ a: UInt32) -> String {
    "\(a >> 24 & 0xFF).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
}

func ipSortKey(_ s: String) -> UInt64 {
    let parts = s.split(separator: ".").compactMap { UInt64($0) }
    guard parts.count == 4 else { return .max }
    return parts.reduce(0) { $0 << 8 | $1 }
}

/// Minimal lock-protected box for bridging callback APIs.
final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func swap(_ v: T) -> T { lock.lock(); defer { lock.unlock() }; let old = value; value = v; return old }
}
