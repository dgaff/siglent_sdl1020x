import Foundation
import Observation

/// One run as listed in the library.
public struct RunEntry: Identifiable, Sendable, Equatable {
    public var id: UUID { info.id }
    public let folder: URL
    public var info: RunInfo

    public var title: String { info.title }
    public var started: Date { info.startedAt }
    public var capacity: Double { info.summary.capacity_mAh }
    public var energy: Double { info.summary.energy_Wh }
    public var duration: Double { info.summary.duration_s }
    public var chemistry: String { info.cell.chemistry }
    public var setpoint: String { "\(info.battery.mode.label) \(info.battery.level.formatted()) \(info.battery.mode.unit)" }
}

/// Browses the run folders (the folders are the source of truth; nothing else to keep in sync).
@MainActor @Observable
public final class LibraryModel {
    public private(set) var entries: [RunEntry] = []
    public private(set) var loading = false
    public var store: RunStore

    private var sampleCache: [UUID: [RunSample]] = [:]
    private var cacheOrder: [UUID] = []
    private static let cacheLimit = 12

    public init(store: RunStore = RunStore()) { self.store = store }

    public func reload() async {
        loading = true
        let s = store
        let runs = await Task.detached { s.allRuns() }.value
        entries = runs.map { RunEntry(folder: $0.folder, info: $0.info) }
        loading = false
    }

    /// Samples for a run, parsed off the main thread and cached (LRU). Active runs bypass the cache.
    public func samples(for e: RunEntry) async -> [RunSample] {
        if e.info.status != .running, let c = sampleCache[e.id] { touch(e.id); return c }
        let s = store, folder = e.folder
        let loaded = await Task.detached { s.loadSamples(folder) }.value
        if e.info.status != .running {
            sampleCache[e.id] = loaded
            touch(e.id)
        }
        return loaded
    }

    private func touch(_ id: UUID) {
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > Self.cacheLimit { sampleCache[cacheOrder.removeFirst()] = nil }
    }

    /// Saves edited metadata (title, cell info, notes). Settings/measurements are not editable.
    public func update(_ e: RunEntry, title: String, cell: CellInfo) throws {
        var info = try store.load(e.folder)
        info.title = title
        info.cell = cell
        try store.save(info, in: e.folder)
        if let i = entries.firstIndex(where: { $0.id == e.id }) { entries[i].info = info }
    }

    /// Moves a finished run's folder to the Trash.
    public func moveToTrash(_ e: RunEntry) throws {
        guard e.info.status != .running else { return }
        try FileManager.default.trashItem(at: e.folder, resultingItemURL: nil)
        entries.removeAll { $0.id == e.id }
        sampleCache[e.id] = nil
    }

    public func entry(_ id: UUID) -> RunEntry? { entries.first { $0.id == id } }
}
