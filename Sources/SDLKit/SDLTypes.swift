import Foundation

/// Static/transient load mode. `scpi` is the argument token; `reply` is what queries return.
public enum LoadMode: String, Sendable, CaseIterable, Codable, Identifiable {
    case cc, cv, cp, cr, led
    public var id: String { rawValue }

    public var scpi: String {
        switch self {
        case .cc: "CURRent"
        case .cv: "VOLTage"
        case .cp: "POWer"
        case .cr: "RESistance"
        case .led: "LED"
        }
    }

    /// Subsystem root used for mode-specific settings (`:CURR:IRANG`, `:LED:VRANG`, ...).
    public var subsystem: String {
        switch self {
        case .cc: ":CURR"
        case .cv: ":VOLT"
        case .cp: ":POW"
        case .cr: ":RES"
        case .led: ":LED"
        }
    }

    public var label: String { rawValue.uppercased() }

    /// Unit of the static set value.
    public var unit: String {
        switch self {
        case .cc: "A"
        case .cv: "V"
        case .cp: "W"
        case .cr: "Ω"
        case .led: "V"
        }
    }

    /// Parses replies such as `CURRENT`, `VOLTAGE`, `POWER`, `RESISTANCE`, `LED`, `CURR`.
    public init?(reply: String) {
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch true {
        case r.hasPrefix("CURR"): self = .cc
        case r.hasPrefix("VOLT"): self = .cv
        case r.hasPrefix("POW"): self = .cp
        case r.hasPrefix("RES"): self = .cr
        case r.hasPrefix("LED"): self = .led
        default: return nil
        }
    }
}

public enum CurrentRange: Double, Sendable, CaseIterable, Codable, Identifiable {
    case low = 5, high = 30
    public var id: Double { rawValue }
    public var label: String { "\(Int(rawValue)) A" }
    public init(reply: Double) { self = reply > 5.5 ? .high : .low }
}

public enum VoltageRange: Double, Sendable, CaseIterable, Codable, Identifiable {
    case low = 36, high = 150
    public var id: Double { rawValue }
    public var label: String { "\(Int(rawValue)) V" }
    public init(reply: Double) { self = reply > 37 ? .high : .low }
}

public enum ResistanceRange: String, Sendable, CaseIterable, Codable, Identifiable {
    case low = "LOW", middle = "MIDDLE", high = "HIGH", upper = "UPPER"
    public var id: String { rawValue }
    /// Nominal span per the user manual (SDL1020X).
    public var label: String {
        switch self {
        case .low: "30 mΩ – 30 Ω"
        case .middle: "30 Ω – 300 Ω"   // verify against device
        case .high: "300 Ω – 3 kΩ"
        case .upper: "3 kΩ – 10 kΩ"
        }
    }
    public init?(reply: String) {
        self.init(rawValue: reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
}

public enum TransientMode: String, Sendable, CaseIterable, Codable, Identifiable {
    case continuous = "CONTinuous", pulse = "PULSe", toggle = "TOGGle"
    public var id: String { rawValue }
    public var label: String {
        switch self { case .continuous: "Continuous"; case .pulse: "Pulse"; case .toggle: "Toggle" }
    }
    public init?(reply: String) {
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if r.hasPrefix("CONT") { self = .continuous }
        else if r.hasPrefix("PULS") { self = .pulse }
        else if r.hasPrefix("TOGG") { self = .toggle }
        else { return nil }
    }
}

public enum TriggerSource: String, Sendable, CaseIterable, Codable, Identifiable {
    case manual = "MANUal", external = "EXTernal", bus = "BUS"
    public var id: String { rawValue }
    public var label: String {
        switch self { case .manual: "Manual"; case .external: "External"; case .bus: "Bus" }
    }
    public init?(reply: String) {
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if r.hasPrefix("MAN") { self = .manual }
        else if r.hasPrefix("EXT") { self = .external }
        else if r.hasPrefix("BUS") { self = .bus }
        else { return nil }
    }
}

/// External sink mode (EXT:MODE).
public enum ExternalMode: String, Sendable, CaseIterable, Codable, Identifiable {
    case internalControl = "INT", externalCurrent = "EXTI", externalVoltage = "EXTV"
    public var id: String { rawValue }
    public init?(reply: String) {
        self.init(rawValue: reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
}

/// Battery test discharge mode (CC/CP/CR only).
public enum BatteryMode: String, Sendable, CaseIterable, Codable, Identifiable {
    case cc = "CURRent", cp = "POWer", cr = "RESistance"
    public var id: String { rawValue }
    public var label: String { switch self { case .cc: "CC"; case .cp: "CP"; case .cr: "CR" } }
    public var unit: String { switch self { case .cc: "A"; case .cp: "W"; case .cr: "Ω" } }
    public init?(reply: String) {
        guard let m = LoadMode(reply: reply) else { return nil }
        switch m { case .cc: self = .cc; case .cp: self = .cp; case .cr: self = .cr; default: return nil }
    }
}

/// One reading of the main measurements.
public struct Reading: Sendable, Equatable, Codable {
    public var voltage: Double
    public var current: Double
    public var power: Double
    public var resistance: Double
    public var date: Date

    public init(voltage: Double, current: Double, power: Double, resistance: Double, date: Date = Date()) {
        self.voltage = voltage; self.current = current
        self.power = power; self.resistance = resistance; self.date = date
    }

    /// Builds a reading from V and I only (P and R derived), for fast polling.
    public static func derived(voltage v: Double, current i: Double, date: Date = Date()) -> Reading {
        Reading(voltage: v, current: i, power: v * i,
                    resistance: abs(i) > 1e-6 ? v / i : 0, date: date)
    }

    public static let zero = Reading(voltage: 0, current: 0, power: 0, resistance: 0)
}

/// A List-function step.
public struct ListStep: Sendable, Equatable, Codable, Identifiable {
    public var id = UUID()
    public var level: Double
    public var width: Double      // seconds
    public var slew: Double       // A/µs (CC only)
    public init(level: Double, width: Double, slew: Double = 0.5) {
        self.level = level; self.width = width; self.slew = slew
    }
    public func sameValues(as o: ListStep) -> Bool {
        approx(level, o.level) && approx(width, o.width) && approx(slew, o.slew)
    }
    public var summary: String { "level \(level) width \(width) slew \(slew)" }
}

func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(1e-6, abs(a) * 1e-6) }

/// A Program-function step.
public struct ProgramStep: Sendable, Equatable, Codable, Identifiable {
    public var id = UUID()
    public var mode: LoadMode = .cc
    public var currentRange: CurrentRange = .high
    public var voltageRange: VoltageRange = .high
    public var resistanceRange: ResistanceRange = .low
    public var pause = false
    public var short = false
    public var timeOn = 1.0
    public var timeOff = 1.0
    public var timeDelay = 1.0
    public var min = 1.0
    public var max = 10.0
    public var level = 1.0
    public var ledCurrent = 1.0   // Io (LED mode)
    public var ledRco = 0.2       // Rco (LED mode)
    public init() {}

    public func sameValues(as o: ProgramStep) -> Bool {
        mode == o.mode && currentRange == o.currentRange && voltageRange == o.voltageRange
            && resistanceRange == o.resistanceRange && pause == o.pause && short == o.short
            && approx(timeOn, o.timeOn) && approx(timeOff, o.timeOff) && approx(timeDelay, o.timeDelay)
            && approx(min, o.min) && approx(max, o.max) && approx(level, o.level)
            && approx(ledCurrent, o.ledCurrent) && approx(ledRco, o.ledRco)
    }
    public var summary: String {
        "\(mode.label) I\(Int(currentRange.rawValue)) V\(Int(voltageRange.rawValue)) \(resistanceRange.rawValue) "
            + "pause \(pause) short \(short) on \(timeOn) off \(timeOff) dly \(timeDelay) "
            + "min \(min) max \(max) lev \(level) Io \(ledCurrent) Rco \(ledRco)"
    }
}
