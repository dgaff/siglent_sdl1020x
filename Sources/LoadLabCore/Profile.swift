import Foundation
import SDLKit

/// Load mode a profile step can use (Basic static modes that make sense for discharging).
public enum StepMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case cc, cp, cr
    public var id: String { rawValue }
    public var loadMode: LoadMode {
        switch self { case .cc: .cc; case .cp: .cp; case .cr: .cr }
    }
    public var label: String { rawValue.uppercased() }
    public var unit: String {
        switch self { case .cc: "A"; case .cp: "W"; case .cr: "Ω" }
    }
}

/// One step of an app-scripted discharge profile.
///
/// A flat struct (rather than an enum with payloads) so the editor can bind to fields
/// directly. Which fields matter depends on `kind`; see the comments.
public struct ProfileStep: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Hold `mode`/`level` until `duration` (s), `untilCapacity` (mAh delivered in this
        /// step) or `untilVoltage` (V under load), whichever comes first. With none set, the
        /// step runs until the profile's cut-off.
        case hold
        /// Input off for `duration` seconds.
        case rest
        /// `count` pulses: `level` for `duration` s, then `level2` for `duration2` s (CC/CP/CR).
        case pulse
        /// Two-current DC resistance: `level` A for `duration` s, then `level2` A for
        /// `duration2` s; R = ΔV / ΔI from the readings at the end of each part.
        case dcr
        /// Repeats `children` up to `count` times, or until `untilCapacity` (mAh, whole run)
        /// or `untilVoltage` (last loaded V) is reached. The profile cut-off also ends it.
        case loop
        /// Adds a labelled event to the recording.
        case mark

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .hold: "Hold"
            case .rest: "Rest"
            case .pulse: "Pulse train"
            case .dcr: "DC resistance"
            case .loop: "Repeat"
            case .mark: "Mark"
            }
        }
        public var symbol: String {
            switch self {
            case .hold: "arrow.down.right"
            case .rest: "pause"
            case .pulse: "waveform.path"
            case .dcr: "bolt.horizontal"
            case .loop: "repeat"
            case .mark: "flag"
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    public var mode: StepMode = .cc
    public var level: Double = 0
    public var level2: Double = 0
    public var duration: Double?
    public var duration2: Double?
    public var count: Int?
    public var untilCapacity: Double?
    public var untilVoltage: Double?
    public var label = ""
    public var children: [ProfileStep] = []

    public init(kind: Kind) { self.kind = kind }

    // Convenience constructors (used by templates and tests).
    public static func hold(_ mode: StepMode = .cc, _ level: Double, duration: Double? = nil,
                            untilCapacity: Double? = nil, untilVoltage: Double? = nil, label: String = "") -> ProfileStep {
        var s = ProfileStep(kind: .hold)
        s.mode = mode; s.level = level; s.duration = duration
        s.untilCapacity = untilCapacity; s.untilVoltage = untilVoltage; s.label = label
        return s
    }
    public static func rest(_ seconds: Double) -> ProfileStep {
        var s = ProfileStep(kind: .rest); s.duration = seconds; return s
    }
    public static func pulse(_ mode: StepMode = .cc, high: Double, highSeconds: Double, low: Double, lowSeconds: Double, count: Int) -> ProfileStep {
        var s = ProfileStep(kind: .pulse)
        s.mode = mode; s.level = high; s.duration = highSeconds; s.level2 = low; s.duration2 = lowSeconds; s.count = count
        return s
    }
    public static func dcr(i1: Double, t1: Double, i2: Double, t2: Double) -> ProfileStep {
        var s = ProfileStep(kind: .dcr)
        s.mode = .cc; s.level = i1; s.duration = t1; s.level2 = i2; s.duration2 = t2
        return s
    }
    public static func loop(_ children: [ProfileStep], count: Int? = nil, untilCapacity: Double? = nil, untilVoltage: Double? = nil) -> ProfileStep {
        var s = ProfileStep(kind: .loop)
        s.children = children; s.count = count; s.untilCapacity = untilCapacity; s.untilVoltage = untilVoltage
        return s
    }
    public static func mark(_ text: String) -> ProfileStep {
        var s = ProfileStep(kind: .mark); s.label = text; return s
    }

    /// One-line description for lists and the event log.
    public var summary: String {
        func n(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...3))) }
        func t(_ s: Double?) -> String { s.map { Self.formatSeconds($0) } ?? "?" }
        switch kind {
        case .hold:
            var ends: [String] = []
            if let d = duration { ends.append(Self.formatSeconds(d)) }
            if let q = untilCapacity { ends.append("\(n(q)) mAh") }
            if let v = untilVoltage { ends.append("≤ \(n(v)) V") }
            return "\(mode.label) \(n(level)) \(mode.unit)" + (ends.isEmpty ? " until cut-off" : " for " + ends.joined(separator: " / "))
        case .rest: return "Input off \(t(duration))"
        case .pulse:
            return "\(count ?? 0)× [\(n(level)) \(mode.unit) \(t(duration)) / \(n(level2)) \(mode.unit) \(t(duration2))]"
        case .dcr: return "\(n(level)) A \(t(duration)) → \(n(level2)) A \(t(duration2))"
        case .loop:
            var ends: [String] = []
            if let c = count { ends.append("\(c)×") }
            if let q = untilCapacity { ends.append("until \(n(q)) mAh") }
            if let v = untilVoltage { ends.append("until ≤ \(n(v)) V") }
            return "\(children.count) step\(children.count == 1 ? "" : "s"), " + (ends.isEmpty ? "until cut-off" : ends.joined(separator: ", "))
        case .mark: return label.isEmpty ? "(no label)" : label
        }
    }

    public static func formatSeconds(_ s: Double) -> String {
        if s < 60 { return "\(s.formatted(.number.precision(.fractionLength(0...1)))) s" }
        if s < 3600 { return "\((s / 60).formatted(.number.precision(.fractionLength(0...1)))) min" }
        return "\((s / 3600).formatted(.number.precision(.fractionLength(0...2)))) h"
    }
}

/// Limits the app enforces on every sample, plus the instrument-side failsafe.
public struct SafetyLimits: Codable, Sendable, Equatable {
    /// End of discharge: a reading under load at or below this ends the profile. Also arms
    /// the instrument's Von (latch off) just below it, so the load stops by itself if the Mac
    /// or network goes away.
    public var cutoffVoltage: Double = 3.0
    /// Abort if the measured current exceeds this (plus a small tolerance).
    public var maxCurrent: Double = 1.0
    /// Optional overall limits.
    public var maxCapacity_mAh: Double?
    public var maxDuration_s: Double?
    /// Von = cutoff − margin, latch off.
    public var hardwareMargin: Double = 0.1
    public init() {}

    /// Measured current above `maxCurrent` by more than this aborts.
    public var currentTolerance: Double { max(0.02, maxCurrent * 0.05) }
}

/// A named, saved discharge profile.
public struct Profile: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var notes = ""
    public var steps: [ProfileStep]
    public var limits = SafetyLimits()
    public var currentRange: CurrentRange = .low
    public var voltageRange: VoltageRange = .low
    public var resistanceRange: ResistanceRange = .low
    public var sampleRateHz: Double = 2
    public var modified = Date()

    public init(name: String, steps: [ProfileStep], limits: SafetyLimits = SafetyLimits()) {
        self.name = name
        self.steps = steps
        self.limits = limits
    }

    /// Every step, depth first (loops included, not expanded).
    public var allSteps: [ProfileStep] {
        func walk(_ s: [ProfileStep]) -> [ProfileStep] { s.flatMap { [$0] + walk($0.children) } }
        return walk(steps)
    }

    /// Largest CC level used anywhere (A).
    public var maxCCLevel: Double {
        allSteps.filter { $0.mode == .cc && [.hold, .pulse, .dcr].contains($0.kind) }
            .flatMap { $0.kind == .hold ? [$0.level] : [$0.level, $0.level2] }.max() ?? 0
    }

    public var modesUsed: Set<StepMode> {
        Set(allSteps.filter { [.hold, .pulse, .dcr].contains($0.kind) }.map(\.mode))
    }

    /// Problems that prevent starting. Empty means OK.
    public func validate() -> [String] {
        var out: [String] = []
        let l = limits
        if l.cutoffVoltage <= 0 { out.append("Set a cut-off voltage above 0 V.") }
        if l.cutoffVoltage - l.hardwareMargin < 0 { out.append("The hardware margin is larger than the cut-off voltage.") }
        if l.maxCurrent <= 0 { out.append("Set a maximum current above 0 A.") }
        if l.maxCurrent > currentRange.rawValue { out.append("The maximum current is above the \(currentRange.label) range.") }
        if !allSteps.contains(where: { [.hold, .pulse, .dcr].contains($0.kind) }) { out.append("Add at least one step that loads the cell.") }
        if maxCCLevel > l.maxCurrent { out.append("A step draws \(maxCCLevel.formatted()) A, above the \(l.maxCurrent.formatted()) A limit.") }
        for (i, s) in allSteps.enumerated() {
            let name = "Step \(i + 1) (\(s.kind.label))"
            switch s.kind {
            case .hold:
                if !levelOK(s.mode, s.level) { out.append("\(name): level out of range.") }
                if let v = s.untilVoltage, v <= l.cutoffVoltage { out.append("\(name): its end voltage must be above the cut-off (\(l.cutoffVoltage.formatted()) V).") }
                if let d = s.duration, d <= 0 { out.append("\(name): duration must be positive.") }
            case .rest:
                if (s.duration ?? 0) <= 0 { out.append("\(name): set a rest time.") }
            case .pulse:
                if !levelOK(s.mode, s.level) || !levelOK(s.mode, s.level2) { out.append("\(name): level out of range.") }
                if (s.duration ?? 0) < Self.minimumPulseWidth || (s.duration2 ?? 0) < Self.minimumPulseWidth {
                    out.append("\(name): each part must last at least \(Self.minimumPulseWidth.formatted()) s (LoadLab switches levels over the network). For faster pulses use Basic → Dynamic.")
                }
                if (s.count ?? 0) < 1 { out.append("\(name): set the number of pulses.") }
            case .dcr:
                if s.mode != .cc { out.append("\(name): DC resistance uses CC.") }
                if abs(s.level2 - s.level) < 0.01 { out.append("\(name): the two currents must differ.") }
                if !levelOK(.cc, s.level) || !levelOK(.cc, s.level2) { out.append("\(name): current out of range.") }
                if (s.duration ?? 0) < 1 || (s.duration2 ?? 0) < 1 { out.append("\(name): each part must last at least 1 s.") }
            case .loop:
                if s.children.isEmpty { out.append("\(name): add steps inside the repeat.") }
                if s.count == nil && s.untilCapacity == nil && s.untilVoltage == nil
                    && !s.children.contains(where: { [.hold, .pulse, .dcr].contains($0.kind) }) {
                    out.append("\(name): a repeat without a count or end condition must load the cell (so the cut-off can end it).")
                }
                if let c = s.count, c < 1 { out.append("\(name): the count must be at least 1.") }
            case .mark: break
            }
        }
        return out
    }

    /// Shortest pulse part LoadLab will time itself (each level change is a network round trip
    /// of 30–250 ms).
    public static let minimumPulseWidth = 1.0

    private func levelOK(_ m: StepMode, _ v: Double) -> Bool {
        switch m {
        case .cc: v >= 0 && v <= currentRange.rawValue
        case .cp: v >= 0 && v <= 200
        case .cr: v >= 0.03 && v <= 10_000
        }
    }
}

// MARK: - Templates

public enum ProfileTemplate: String, CaseIterable, Identifiable, Sendable {
    case capacity, multiRate, pulse, hppc, constantPower
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .capacity: "Constant-current capacity"
        case .multiRate: "Multi-rate (rate capability)"
        case .pulse: "Pulse discharge"
        case .hppc: "Internal resistance vs state of charge"
        case .constantPower: "Constant-power runtime"
        }
    }
    public var blurb: String {
        switch self {
        case .capacity: "Discharge at one current to the cut-off. Like the instrument's Battery test, with LoadLab's extra safety layers."
        case .multiRate: "Discharge at a high rate to the cut-off, rest, then continue at lower rates. The capacity each rate adds shows how the cell copes with load."
        case .pulse: "Repeated high-current bursts over a light base load (radio transmit, motor start) until the cut-off."
        case .hppc: "At each state of charge: rest, measure DC resistance with a two-current pulse, then discharge a slice of capacity. Gives an internal-resistance-vs-SoC curve."
        case .constantPower: "Constant power to the cut-off: how long a device with a DC-DC converter would run."
        }
    }

    /// Builds the template for a cell. `maxCurrent` caps every level (the bench rule is < 1 A).
    public func make(cell: CellInfo, maxCurrent: Double = 0.9) -> Profile {
        let nominal = cell.nominalCapacity_mAh ?? 2000
        let cutoff = cell.suggestedCutoff ?? 3.0
        func c(_ rate: Double) -> Double { (min(nominal * rate / 1000, maxCurrent) * 1000).rounded() / 1000 }
        var limits = SafetyLimits()
        limits.cutoffVoltage = cutoff
        limits.maxCurrent = maxCurrent
        var p: Profile
        switch self {
        case .capacity:
            p = Profile(name: title, steps: [.mark("Discharge"), .hold(.cc, c(0.5))], limits: limits)
        case .multiRate:
            // The rate segments end slightly above the hard cut-off so each can reach "its" knee.
            let stepEnd = cutoff + 0.05
            var steps: [ProfileStep] = []
            for (k, rate) in [1.0, 0.5, 0.2].enumerated() {
                if k > 0 { steps.append(.rest(300)) }
                steps.append(.mark("\(rate.formatted()) C"))
                steps.append(.hold(.cc, c(rate), untilVoltage: stepEnd))
            }
            p = Profile(name: title, steps: steps, limits: limits)
        case .pulse:
            p = Profile(name: title, steps: [
                .loop([.pulse(.cc, high: c(1), highSeconds: 2, low: c(0.1), lowSeconds: 8, count: 30)])
            ], limits: limits)
        case .hppc:
            let slice = (nominal * 0.1).rounded()
            p = Profile(name: title, steps: [
                .loop([
                    .rest(60),
                    .dcr(i1: c(0.1), t1: 10, i2: c(1), t2: 2),
                    .hold(.cc, c(0.5), untilCapacity: slice),
                ], count: 12)
            ], limits: limits)
        case .constantPower:
            // Sized at the cut-off voltage, where a constant-power load draws the most current.
            let watts = (cutoff * c(0.5) * 100).rounded(.down) / 100
            p = Profile(name: title, steps: [.hold(.cp, watts)], limits: limits)
        }
        p.currentRange = maxCurrent <= 5 ? .low : .high
        p.voltageRange = cutoff * 1.5 + 1 <= 36 ? .low : .high
        return p
    }
}

// MARK: - Editing helpers (steps addressed by id; loops nest)

extension Profile {
    /// Index path of a step (indices into nested `children`).
    public func path(of id: UUID) -> [Int]? {
        func find(_ steps: [ProfileStep], _ prefix: [Int]) -> [Int]? {
            for (i, s) in steps.enumerated() {
                if s.id == id { return prefix + [i] }
                if let p = find(s.children, prefix + [i]) { return p }
            }
            return nil
        }
        return find(steps, [])
    }

    public func step(_ id: UUID) -> ProfileStep? { allSteps.first { $0.id == id } }

    /// Applies `body` to the sibling array that holds `path.last`.
    private mutating func withSiblings(of path: [Int], _ body: (inout [ProfileStep], Int) -> Void) {
        func go(_ steps: inout [ProfileStep], _ p: ArraySlice<Int>) {
            if p.count == 1 { body(&steps, p.first!); return }
            go(&steps[p.first!].children, p.dropFirst())
        }
        guard !path.isEmpty else { return }
        go(&steps, path[...])
    }

    public mutating func update(_ step: ProfileStep) {
        guard let p = path(of: step.id) else { return }
        withSiblings(of: p) { arr, i in arr[i] = step }
    }

    /// Inserts after `after` (same level), or at the end when nil.
    public mutating func insert(_ step: ProfileStep, after: UUID?) {
        guard let a = after, let p = path(of: a) else { steps.append(step); return }
        withSiblings(of: p) { arr, i in arr.insert(step, at: i + 1) }
    }

    /// Appends inside a loop.
    public mutating func append(_ step: ProfileStep, into loop: UUID) {
        guard var l = self.step(loop), l.kind == .loop else { return }
        l.children.append(step)
        update(l)
    }

    public mutating func remove(_ id: UUID) {
        guard let p = path(of: id) else { return }
        withSiblings(of: p) { arr, i in arr.remove(at: i) }
    }

    public mutating func move(_ id: UUID, by offset: Int) {
        guard let p = path(of: id) else { return }
        withSiblings(of: p) { arr, i in
            let j = i + offset
            guard arr.indices.contains(j) else { return }
            arr.swapAt(i, j)
        }
    }

    /// Rows for an outline display.
    public var rows: [(step: ProfileStep, depth: Int)] {
        func walk(_ s: [ProfileStep], _ d: Int) -> [(ProfileStep, Int)] { s.flatMap { [($0, d)] + walk($0.children, d + 1) } }
        return walk(steps, 0)
    }

    /// Rough duration estimate in seconds, or nil when it depends on the cell (until cut-off).
    public func estimatedDuration(capacity_mAh: Double?) -> Double? {
        func est(_ s: [ProfileStep]) -> Double? {
            var total = 0.0
            for x in s {
                switch x.kind {
                case .mark: continue
                case .rest: total += x.duration ?? 0
                case .pulse: total += Double(x.count ?? 0) * ((x.duration ?? 0) + (x.duration2 ?? 0))
                case .dcr: total += (x.duration ?? 0) + (x.duration2 ?? 0)
                case .hold:
                    if let d = x.duration { total += d }
                    else if let q = x.untilCapacity, x.mode == .cc, x.level > 0 { total += q / (x.level * 1000) * 3600 }
                    else if x.mode == .cc, x.level > 0, let c = capacity_mAh { total += c / (x.level * 1000) * 3600 }
                    else { return nil }
                case .loop:
                    guard let n = x.count, let inner = est(x.children) else { return nil }
                    total += Double(n) * inner
                }
            }
            return total
        }
        return est(steps)
    }
}

/// Saved profiles: one JSON file per profile in ~/Documents/LoadLab/Profiles.
public struct ProfileStore: Sendable {
    public let root: URL

    public static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["LOADLAB_PROFILES_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LoadLab/Profiles", isDirectory: true)
    }

    public init(root: URL = ProfileStore.defaultRoot) { self.root = root }

    private func url(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).json") }

    public func all() -> [Profile] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return items.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Profile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ p: Profile) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(p).write(to: url(p.id), options: .atomic)
    }

    public func delete(_ p: Profile) throws {
        let u = url(p.id)
        if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
    }
}
