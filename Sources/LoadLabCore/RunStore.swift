import Foundation

/// File layout for recorded runs:
///
///     <root>/<yyyy-MM-dd_HHmmss>_<title>/run.json     metadata, settings, events, summary
///     <root>/<yyyy-MM-dd_HHmmss>_<title>/samples.csv  one row per sample (streamed, flushed ~1 s)
///
/// CSV is the durable record (crash-safe, opens in anything); Phase 4 indexes these folders.
public struct RunStore: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["LOADLAB_RUNS_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoadLab/Runs", isDirectory: true)
    }

    public init(root: URL = RunStore.defaultRoot) { self.root = root }

    public static let csvHeader =
        "elapsed_s,timestamp,voltage_V,current_A,power_W,resistance_Ohm,capacity_mAh,energy_Wh,device_capacity_mAh,device_time_s"

    public func createFolder(for info: RunInfo) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let slug = info.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { s, c in if !(c == "-" && s.hasSuffix("-")) { s.append(c) } }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let name = "\(f.string(from: info.startedAt))_\(slug.isEmpty ? "run" : String(slug.prefix(40)))"
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func save(_ info: RunInfo, in folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(info).write(to: folder.appendingPathComponent("run.json"), options: .atomic)
    }

    public func load(_ folder: URL) throws -> RunInfo {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(RunInfo.self, from: Data(contentsOf: folder.appendingPathComponent("run.json")))
    }

    /// All run folders, newest first.
    public func allRuns() -> [(folder: URL, info: RunInfo)] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { u in (try? load(u)).map { (u, $0) } }
            .sorted { $0.info.startedAt > $1.info.startedAt }
    }

    /// Runs still marked running for a given instrument (the app quit or crashed mid-run).
    public func runningRuns(serial: String?) -> [(folder: URL, info: RunInfo)] {
        allRuns().filter { $0.info.status == .running && $0.info.deviceSerial == serial }
    }

    /// Reads samples back from a CSV (used for resume and, later, the library).
    public func loadSamples(_ folder: URL) -> [RunSample] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("samples.csv"), encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [RunSample] = []
        for line in text.split(separator: "\n").dropFirst() {
            let c = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 8, let t = Double(c[0]), let d = iso.date(from: c[1]),
                  let v = Double(c[2]), let i = Double(c[3]), let p = Double(c[4]), let r = Double(c[5]),
                  let q = Double(c[6]), let e = Double(c[7]) else { continue }
            out.append(RunSample(t: t, date: d, voltage: v, current: i, power: p, resistance: r, capacity_mAh: q, energy_Wh: e))
        }
        return out
    }
}

/// Appends CSV rows, flushing to disk periodically so a crash loses at most ~1 s.
final class CSVWriter {
    private let handle: FileHandle
    private var pending = ""
    private var lastFlush = Date()
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try (RunStore.csvHeader + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ s: RunSample, deviceCapacity: Double?, deviceTime: Double?) {
        func f(_ v: Double, _ d: Int) -> String { String(format: "%.\(d)f", v) }
        pending += [f(s.t, 3), iso.string(from: s.date), f(s.voltage, 6), f(s.current, 6), f(s.power, 6),
                    f(s.resistance, 4), f(s.capacity_mAh, 4), f(s.energy_Wh, 6),
                    deviceCapacity.map { f($0, 0) } ?? "", deviceTime.map { f($0, 0) } ?? ""].joined(separator: ",") + "\n"
        if Date().timeIntervalSince(lastFlush) >= 1 { flush() }
    }

    func flush() {
        guard !pending.isEmpty else { return }
        handle.write(Data(pending.utf8))
        try? handle.synchronize()
        pending = ""
        lastFlush = Date()
    }

    func close() {
        flush()
        try? handle.close()
    }
}
