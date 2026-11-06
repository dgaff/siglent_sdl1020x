import Foundation
import SDLKit

/// List function settings (mirrors the instrument).
public struct ListConfig: Equatable, Sendable, Codable {
    public var mode: LoadMode = .cc
    public var currentRange: CurrentRange = .high
    public var voltageRange: VoltageRange = .high
    public var resistanceRange: ResistanceRange = .low
    /// Times the whole list repeats (1–255).
    public var count = 1
    public var steps: [ListStep] = [ListStep(level: 2, width: 1, slew: 0.5)]
    public init() {}

    public static let modes: [LoadMode] = [.cc, .cv, .cp, .cr]

    public var levelRange: ClosedRange<Double> {
        SDLLimits.level(mode, currentRange: currentRange, voltageRange: voltageRange)
    }
    public var cycleSeconds: Double { steps.map(\.width).reduce(0, +) }
    public var totalSeconds: Double { cycleSeconds * Double(max(count, 1)) }

    public func validate() -> [String] {
        var out: [String] = []
        if steps.isEmpty { out.append("Add at least one step.") }
        if steps.count > SDLLimits.listSteps.upperBound { out.append("At most \(SDLLimits.listSteps.upperBound) steps.") }
        if !(1...255).contains(count) { out.append("Repeat count must be 1–255.") }
        for (i, s) in steps.enumerated() {
            if !levelRange.contains(s.level) { out.append("Step \(i + 1): level outside \(levelRange.lowerBound.formatted())–\(levelRange.upperBound.formatted()) \(mode.unit).") }
            if s.width <= 0 { out.append("Step \(i + 1): width must be positive.") }
        }
        return out
    }
}

/// Program function settings. Each step's result is measured by the instrument.
public struct ProgramConfig: Equatable, Sendable, Codable {
    public var steps: [ProgramStep] = [ProgramStep()]
    public var stopOnFail = false
    public init() {}

    public func validate() -> [String] {
        var out: [String] = []
        if steps.isEmpty { out.append("Add at least one step.") }
        if steps.count > SDLLimits.programSteps.upperBound { out.append("At most \(SDLLimits.programSteps.upperBound) steps.") }
        for (i, s) in steps.enumerated() {
            if s.timeOn <= 0 { out.append("Step \(i + 1): on-time must be positive.") }
            if s.min > s.max { out.append("Step \(i + 1): min is above max.") }
            if !s.short, !SDLLimits.level(s.mode, currentRange: s.currentRange, voltageRange: s.voltageRange).contains(s.level) {
                out.append("Step \(i + 1): level out of range.")
            }
        }
        return out
    }
}

extension ProgramStep {
    /// What the instrument measures to judge the step: current for CV, voltage otherwise.
    public var measuredQuantity: (name: String, unit: String) {
        mode == .cv ? ("Current", "A") : ("Voltage", "V")
    }
}

/// OCPT / OPPT settings.
public struct ProtectionTestConfig: Equatable, Sendable, Codable {
    public var currentRange: CurrentRange = .high
    public var voltageRange: VoltageRange = .high
    public var start = 1.0
    public var step = 1.0
    public var stepDelay = 1.0
    public var end = 1.0
    public var min = 1.0
    public var max = 1.0
    /// The test sees a trip when the voltage falls below this.
    public var voltage = 1.0
    public init() {}

    public func validate(isPower: Bool) -> [String] {
        var out: [String] = []
        if step <= 0 { out.append("Step must be positive.") }
        if stepDelay <= 0 { out.append("Step delay must be positive.") }
        if end <= start { out.append("End must be above start.") }
        if min > max { out.append("Pass window: min is above max.") }
        if !isPower, end > currentRange.rawValue { out.append("End is above the \(currentRange.label) range.") }
        if voltage <= 0 { out.append("Set the trip voltage.") }
        return out
    }

    /// Worst-case duration if nothing trips.
    public var maxSeconds: Double { step > 0 ? ((end - start) / step).rounded(.up) * stepDelay + stepDelay : 0 }
}

// MARK: - Runs and results

/// A List / Program / OCPT / OPPT run in progress or finished (kept in memory).
public struct SequenceRun: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case running, finished, stopped }
    public var function: ActiveFunction
    public var started = Date()
    public var ended: Date?
    public var phase: Phase = .running
    /// Executing step (List/Program), from `:TEST:STEP?`.
    public var step = 0
    /// Trigger source to put back afterwards (List/Program need BUS to be started remotely).
    public var savedTriggerSource: TriggerSource?
    public var programResults: [ProgramResult] = []
    public var protectionResult: ProtectionResult?
    /// Fast readings taken during OCPT/OPPT (to find the trip point).
    public var trace: [Reading] = []
    /// Why LoadLab ended the run itself, if it did.
    public var note: String?
}

public struct ProgramResult: Equatable, Sendable, Identifiable {
    public var id: Int { step }
    public var step: Int
    public var value: Double
    public var min: Double
    public var max: Double
    public var unit: String
    public var passed: Bool { value >= min && value <= max }
}

public struct ProtectionResult: Equatable, Sendable {
    public var tripped: Bool
    /// Highest current (OCPT) or power (OPPT) held before the trip, or reached without one.
    public var value: Double?
    public var unit: String
    public var min: Double
    public var max: Double
    public var passed: Bool { tripped && (value.map { $0 >= min && $0 <= max } ?? false) }

    public var summary: String {
        guard let v = value else { return "No reading under load" }
        let s = v.formatted(.number.precision(.fractionLength(3)))
        return tripped ? "Tripped at about \(s) \(unit)" : "Did not trip (reached \(s) \(unit))"
    }

    /// Finds the trip point in a trace. The instrument doesn't report it, so: the source
    /// "tripped" if its voltage fell below the threshold once the ramp had started, or the ramp
    /// stopped well short of its end. The trip value is the highest load held while the voltage
    /// was still above the threshold.
    ///
    /// Measured: the ramp stops *before* applying the End level (0.1/0.2 A applied with End
    /// 0.3 A), so reaching the last level below End counts as "no trip". A trip within the last
    /// 1.5 steps that the sampling misses is reported as no trip: keep End clear of the
    /// expected trip point.
    public static func analyse(trace: [Reading], config c: ProtectionTestConfig, isPower: Bool) -> ProtectionResult {
        let unit = isPower ? "W" : "A"
        func load(_ r: Reading) -> Double { isPower ? r.power : r.current }
        guard let first = trace.firstIndex(where: { $0.current > 0.001 }) else {
            return ProtectionResult(tripped: false, value: nil, unit: unit, min: c.min, max: c.max)
        }
        let during = trace[first...]
        let healthy = during.filter { $0.current > 0.001 && $0.voltage >= c.voltage }
        let collapsed = during.contains { $0.voltage < c.voltage }
        let best = healthy.map(load).max()
        let stoppedEarly = (best ?? 0) < c.end - 1.5 * c.step
        return ProtectionResult(tripped: collapsed || (best != nil && stoppedEarly), value: best, unit: unit, min: c.min, max: c.max)
    }
}

// MARK: - CSV for step tables

public enum StepCSV {
    public static let listHeader = "level,width_s,slew_A_per_us"

    public static func list(_ steps: [ListStep]) -> String {
        ([listHeader] + steps.map { "\(fmt($0.level)),\(fmt($0.width)),\(fmt($0.slew))" }).joined(separator: "\n") + "\n"
    }

    public static func parseList(_ text: String) throws -> [ListStep] {
        try rows(text).map { c in
            guard c.count >= 2, let l = Double(c[0]), let w = Double(c[1]) else { throw CSVError.badRow(c.joined(separator: ",")) }
            return ListStep(level: l, width: w, slew: c.count > 2 ? Double(c[2]) ?? 0.5 : 0.5)
        }
    }

    public static let programHeader =
        "mode,current_range_A,voltage_range_V,resistance_range,short,pause,on_s,off_s,delay_s,min,max,level,led_io_A,led_rco"

    public static func program(_ steps: [ProgramStep]) -> String {
        ([programHeader] + steps.map { s in
            [s.mode.rawValue, fmt(s.currentRange.rawValue), fmt(s.voltageRange.rawValue), s.resistanceRange.rawValue,
             s.short ? "1" : "0", s.pause ? "1" : "0", fmt(s.timeOn), fmt(s.timeOff), fmt(s.timeDelay),
             fmt(s.min), fmt(s.max), fmt(s.level), fmt(s.ledCurrent), fmt(s.ledRco)].joined(separator: ",")
        }).joined(separator: "\n") + "\n"
    }

    public static func parseProgram(_ text: String) throws -> [ProgramStep] {
        try rows(text).map { c in
            guard c.count >= 12, let mode = LoadMode(rawValue: c[0].lowercased()),
                  let ir = Double(c[1]), let vr = Double(c[2]), let rr = ResistanceRange(reply: c[3]),
                  let on = Double(c[6]), let off = Double(c[7]), let dly = Double(c[8]),
                  let mn = Double(c[9]), let mx = Double(c[10]), let lev = Double(c[11]) else {
                throw CSVError.badRow(c.joined(separator: ","))
            }
            var s = ProgramStep()
            s.mode = mode; s.currentRange = .init(reply: ir); s.voltageRange = .init(reply: vr); s.resistanceRange = rr
            s.short = c[4] == "1" || c[4].lowercased() == "true"
            s.pause = c[5] == "1" || c[5].lowercased() == "true"
            s.timeOn = on; s.timeOff = off; s.timeDelay = dly; s.min = mn; s.max = mx; s.level = lev
            if c.count > 12, let io = Double(c[12]) { s.ledCurrent = io }
            if c.count > 13, let r = Double(c[13]) { s.ledRco = r }
            return s
        }
    }

    public enum CSVError: Error, CustomStringConvertible, Equatable {
        case badRow(String)
        public var description: String { switch self { case .badRow(let r): "Can't read this row: \(r)" } }
    }

    /// Non-empty data rows (a header row starting with a letter is skipped; # comments too).
    static func rows(_ text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
            .enumerated()
            .filter { i, c in !(i == 0 && (c.first?.first?.isLetter ?? false) && Double(c.first ?? "") == nil && LoadMode(rawValue: c.first?.lowercased() ?? "") == nil) }
            .map(\.1)
    }

    static func fmt(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
