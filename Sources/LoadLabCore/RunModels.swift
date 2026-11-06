import Foundation
import SDLKit

/// Battery-function settings (mirrors the instrument).
public struct BatteryConfig: Equatable, Sendable, Codable {
    public var mode: BatteryMode = .cc
    public var currentRange: CurrentRange = .high
    public var voltageRange: VoltageRange = .high
    public var resistanceRange: ResistanceRange = .low
    /// Discharge value: A (CC), W (CP) or Ω (CR).
    public var level: Double = 1
    public var stopVoltageEnabled = false
    public var stopVoltage: Double = 0          // V
    public var stopCapacityEnabled = false
    public var stopCapacity: Double = 0         // mAh
    public var stopTimeEnabled = false
    public var stopTime: Double = 0             // s
    public init() {}

    public var levelRange: ClosedRange<Double> {
        switch mode {
        case .cc: 0...currentRange.rawValue
        case .cp: 0...200
        case .cr: 0.03...10_000
        }
    }

    public var hasStopCondition: Bool { stopVoltageEnabled || stopCapacityEnabled || stopTimeEnabled }
}

/// Describes the cell or pack under test (user-entered).
public struct CellInfo: Equatable, Sendable, Codable {
    public var name = ""
    public var chemistry = "Li-ion"
    public var nominalCapacity_mAh: Double? = nil
    public var nominalVoltage: Double? = nil
    public var seriesCells = 1
    public var temperatureC: Double? = nil
    public var notes = ""
    public init() {}

    public static let chemistries = ["Li-ion", "LiFePO4", "LiPo", "NiMH", "NiCd", "Lead-acid", "Alkaline", "Other"]
}

/// Options that belong to LoadLab rather than the instrument.
public struct RecordingOptions: Equatable, Sendable, Codable {
    /// Samples per second (1–10). Above 4 Hz only V and I are read (P and R derived).
    public var sampleRateHz: Double = 2
    /// Set Von = V_Stop − margin with latch OFF before starting, as a hardware cutoff that
    /// works even if the Mac or network drops (verified on hardware). Restored afterwards.
    public var hardwareCutoff = true
    public var hardwareCutoffMargin: Double = 0.1
    public init() {}
}

public enum RunStatus: String, Sendable, Codable {
    case running, completed, stopped, interrupted, failed
}

public enum EndReason: String, Sendable, Codable {
    case voltageCutoff, capacityLimit, timeLimit, userStopped, inputSwitchedOff, endedWhileDisconnected, error
    case profileFinished, currentLimit, connectionLost

    public var label: String {
        switch self {
        case .voltageCutoff: "Reached cut-off voltage"
        case .capacityLimit: "Reached capacity limit"
        case .timeLimit: "Reached time limit"
        case .userStopped: "Stopped by user"
        case .inputSwitchedOff: "Input switched off (front panel or protection)"
        case .endedWhileDisconnected: "Ended while LoadLab was disconnected"
        case .error: "Stopped after an error"
        case .profileFinished: "All profile steps done"
        case .currentLimit: "Safety stop: current above the limit"
        case .connectionLost: "Safety stop: connection lost during a profile"
        }
    }
}

public struct RunEvent: Sendable, Codable, Equatable {
    public var t: Double        // elapsed seconds
    public var date: Date
    public var kind: String     // start, gap, reconnect, resume, stop, note
    public var text: String
}

public struct RunSummary: Sendable, Codable, Equatable {
    public var duration_s: Double = 0
    public var capacity_mAh: Double = 0
    public var energy_Wh: Double = 0
    public var deviceCapacity_mAh: Double?
    public var deviceTime_s: Double?
    public var startVoltage: Double?
    public var endVoltage: Double?
    public var minVoltage: Double?
    public var averageVoltage: Double?
    public var averageCurrent: Double?
    public var samples = 0
}

/// Everything about a run except the samples (stored as run.json beside samples.csv).
public struct RunInfo: Sendable, Codable, Identifiable, Equatable {
    public var id = UUID()
    public var kind = "battery"
    public var title: String
    public var cell: CellInfo
    public var battery: BatteryConfig
    public var options: RecordingOptions
    public var deviceModel: String?
    public var deviceSerial: String?
    public var deviceFirmware: String?
    public var deviceHost: String?
    /// Von / latch before the run, restored when it ends.
    public var savedVOn: Double?
    public var savedVOnLatch: Bool?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: RunStatus = .running
    public var endReason: EndReason?
    public var summary = RunSummary()
    public var events: [RunEvent] = []
    public var appVersion = "LoadLab 0.3"
    // Profile runs (kind == "profile"); optional so older run.json files still decode.
    public var profile: Profile?
    public var dcrResults: [DCRResult]?
    /// Basic-mode settings before a profile ran, restored when it ends.
    public var savedBasic: SavedBasic?
}

/// One two-current DC resistance measurement during a profile.
public struct DCRResult: Sendable, Codable, Equatable, Identifiable {
    public var id: Double { t }
    public var t: Double
    public var capacity_mAh: Double
    public var i1: Double
    public var v1: Double
    public var i2: Double
    public var v2: Double
    public var milliohms: Double { abs((v1 - v2) / (i2 - i1)) * 1000 }
    public init(t: Double, capacity_mAh: Double, i1: Double, v1: Double, i2: Double, v2: Double) {
        self.t = t; self.capacity_mAh = capacity_mAh; self.i1 = i1; self.v1 = v1; self.i2 = i2; self.v2 = v2
    }
}

/// The Basic settings a profile changes.
public struct SavedBasic: Sendable, Codable, Equatable {
    public struct Mode: Sendable, Codable, Equatable {
        public var mode: LoadMode
        public var level: Double
        public var currentRange: CurrentRange
        public var voltageRange: VoltageRange
    }
    public var mode: LoadMode
    public var dynamic: Bool
    public var modes: [Mode]
    public var resistanceRange: ResistanceRange
}

/// One recorded sample.
public struct RunSample: Sendable, Equatable, Identifiable {
    public var id: Double { t }
    public let t: Double            // elapsed seconds since start
    public let date: Date
    public let voltage: Double
    public let current: Double
    public let power: Double
    public let resistance: Double
    public let capacity_mAh: Double // app-integrated
    public let energy_Wh: Double    // app-integrated
}

/// Trapezoidal charge/energy integrator.
public struct Integrator: Sendable, Equatable {
    public private(set) var capacity_mAh = 0.0
    public private(set) var energy_Wh = 0.0
    private var last: Point?
    private struct Point: Sendable, Equatable { let date: Date; let current: Double; let power: Double }

    public init(capacity_mAh: Double = 0, energy_Wh: Double = 0) {
        self.capacity_mAh = capacity_mAh
        self.energy_Wh = energy_Wh
    }

    /// Sets the previous point without adding anything (used when resuming a run).
    public mutating func seed(date: Date, current: Double, power: Double) { last = Point(date: date, current: current, power: power) }

    /// Adds one reading. Returns the time step used (0 for the first reading).
    @discardableResult
    public mutating func add(date: Date, current: Double, power: Double) -> Double {
        defer { last = Point(date: date, current: current, power: power) }
        guard let l = last else { return 0 }
        let dt = date.timeIntervalSince(l.date)
        guard dt > 0 else { return 0 }
        capacity_mAh += (l.current + current) / 2 * dt / 3.6
        energy_Wh += (l.power + power) / 2 * dt / 3600
        return dt
    }
}

extension RunSample {
    /// Min/max bucket downsampling (keeps voltage and current extremes per bucket).
    public static func downsample(_ s: [RunSample], maxPoints: Int = 1500) -> [RunSample] {
        guard s.count > maxPoints, maxPoints >= 8 else { return s }
        let buckets = maxPoints / 4
        let size = Double(s.count) / Double(buckets)
        var out: [RunSample] = []
        out.reserveCapacity(maxPoints)
        for b in 0..<buckets {
            let lo = Int(Double(b) * size), hi = min(Int(Double(b + 1) * size), s.count)
            guard lo < hi else { continue }
            var vMin = lo, vMax = lo, iMin = lo, iMax = lo
            for i in lo..<hi {
                if s[i].voltage < s[vMin].voltage { vMin = i }
                if s[i].voltage > s[vMax].voltage { vMax = i }
                if s[i].current < s[iMin].current { iMin = i }
                if s[i].current > s[iMax].current { iMax = i }
            }
            out.append(contentsOf: Set([lo, hi - 1, vMin, vMax, iMin, iMax]).sorted().map { s[$0] })
        }
        return out
    }
}

extension CellInfo {
    /// Typical per-cell discharge cut-off for the chemistry (a starting suggestion only).
    public var suggestedCutoff: Double? {
        let perCell: Double? = switch chemistry {
        case "Li-ion", "LiPo": 3.0
        case "LiFePO4": 2.5
        case "NiMH", "NiCd": 1.0
        case "Lead-acid": 1.75
        case "Alkaline": 0.9
        default: nil
        }
        return perCell.map { $0 * Double(max(seriesCells, 1)) }
    }
}
