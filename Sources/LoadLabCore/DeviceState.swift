import Foundation
import SDLKit

/// Which top-level function the instrument is running.
public enum ActiveFunction: String, Sendable, CaseIterable, Identifiable, Codable {
    case basic, battery, list, program, ocpt, oppt, ext
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .basic: "Basic"
        case .battery: "Battery"
        case .list: "List"
        case .program: "Program"
        case .ocpt: "OCPT"
        case .oppt: "OPPT"
        case .ext: "Ext"
        }
    }
}

/// Per-mode settings for Basic (static and dynamic) operation.
public struct ModeConfig: Equatable, Sendable {
    public var level: Double = 0
    public var currentRange: CurrentRange = .high
    public var voltageRange: VoltageRange = .high
    // Dynamic (transient)
    public var transientMode: TransientMode = .continuous
    public var transientCurrentRange: CurrentRange = .high
    public var transientVoltageRange: VoltageRange = .high
    public var aLevel: Double = 0
    public var bLevel: Double = 0
    public var aWidth: Double = 1
    public var bWidth: Double = 1
    public init() {}
}

/// Mirror of the instrument settings the app shows. Updated from read-backs only.
public struct DeviceState: Equatable, Sendable {
    // Live status
    public var inputOn = false
    public var shortOn = false
    public var function: ActiveFunction = .basic

    // Basic
    public var mode: LoadMode = .cc
    /// Tracked by the app: the instrument has no query that reveals static vs dynamic.
    public var dynamic = false
    public var modes: [LoadMode: ModeConfig] = Dictionary(uniqueKeysWithValues: LoadMode.allCases.map { ($0, ModeConfig()) })
    public var resistanceRange: ResistanceRange = .low
    public var slewRise = 0.5
    public var slewFall = 0.5
    public var transientSlewRise = 0.5
    public var transientSlewFall = 0.5
    public var ledVoltage = 0.0
    public var ledCurrent = 0.0
    public var ledRco = 0.2

    // System / utility
    public var sense = false
    public var vOn = 0.0
    public var vOnLatch = false
    public var currentProtection = ProtectionConfig()
    public var powerProtection = ProtectionConfig()
    public var averageExponent = 9
    public var triggerSource: TriggerSource = .manual
    public var stopOnFail = false
    public var extInputSwitch = false
    public var currentMonitor = false
    public var voltageMonitor = false
    public var externalMode: ExternalMode = .internalControl

    public init() {}

    public subscript(mode m: LoadMode) -> ModeConfig {
        get { modes[m] ?? ModeConfig() }
        set { modes[m] = newValue }
    }

    /// Current/voltage range in effect for the selected mode (static or dynamic).
    public var activeCurrentRange: CurrentRange {
        dynamic ? self[mode: mode].transientCurrentRange : self[mode: mode].currentRange
    }
    public var activeVoltageRange: VoltageRange {
        dynamic ? self[mode: mode].transientVoltageRange : self[mode: mode].voltageRange
    }
}

public struct ProtectionConfig: Equatable, Sendable {
    public var enabled = false
    public var level = 0.0
    public var delay = 0.0
    public init() {}
}
