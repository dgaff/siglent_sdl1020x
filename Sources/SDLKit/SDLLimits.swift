import Foundation

/// Setting limits for the SDL1020X, measured on hardware (fw 1.1.1.23R4) by setting
/// `MINimum`/`MAXimum` and reading back. Out-of-range writes are silently *clamped* to the
/// limit (slew, widths, CC level) or silently *ignored* (CR level below 30 mΩ), so the app
/// must clamp before sending and read back after.
public enum SDLLimits {
    public static func slew(_ range: CurrentRange) -> ClosedRange<Double> {
        range == .low ? 0.001...0.5 : 0.001...2.5
    }

    public static func level(_ mode: LoadMode, currentRange: CurrentRange, voltageRange: VoltageRange) -> ClosedRange<Double> {
        switch mode {
        case .cc: 0...currentRange.rawValue
        case .cv, .led: 0...voltageRange.rawValue
        case .cp: 0...200
        case .cr: 0.03...10_000
        }
    }

    /// Transient A/B width (seconds). Note CV's 1 s minimum.
    public static func transientWidth(_ mode: LoadMode) -> ClosedRange<Double> {
        switch mode {
        case .cc: 0.000_020...999
        case .cv: 1...999
        case .cp: 0.000_040...999
        case .cr, .led: 0.001...999
        }
    }

    public static let vOn: ClosedRange<Double> = 0...150
    public static let listSteps: ClosedRange<Int> = 1...100
    /// The front panel documents 0 = infinite; over SCPI MINimum reads back 1 (0 unverified).
    public static let listCount: ClosedRange<Int> = 0...255
    public static let programSteps: ClosedRange<Int> = 1...50
    public static let dcrTimeMinimum = 0.02
    public static let averageExponent: ClosedRange<Int> = 6...14
}
