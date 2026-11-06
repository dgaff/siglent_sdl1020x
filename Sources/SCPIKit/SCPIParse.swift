import Foundation

/// Lenient parsers for instrument replies.
public enum SCPIParse {
    /// Parses floats like `0.200000`, `+5.00000000E+00`, and unit-suffixed `8s`, `30A`.
    public static func double(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = Double(t) { return v }
        // Strip a trailing alphabetic unit suffix.
        var end = t.endIndex
        while end > t.startIndex, t[t.index(before: end)].isLetter { end = t.index(before: end) }
        return Double(t[..<end])
    }

    /// Parses `1`/`0`/`ON`/`OFF`.
    public static func bool(_ s: String) -> Bool? {
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "1", "ON": true
        case "0", "OFF": false
        default: nil
        }
    }

    /// Parses a comma-separated float list (e.g. `MEAS:WAVEdata?`).
    public static func doubles(_ s: String) -> [Double] {
        s.split(separator: ",").compactMap { double(String($0)) }
    }

    /// Parses `SYST:ERR?` replies like `+0, No error` or `-113,Undefined header,:BATT:DISCH:CAP?`.
    public static func error(_ s: String) -> (code: Int, message: String)? {
        let parts = s.split(separator: ",", maxSplits: 1)
        guard let first = parts.first,
              let code = Int(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        let msg = parts.count > 1 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"")) : ""
        return (code, msg)
    }
}

/// `*IDN?` reply, e.g. `Siglent Technologies,SDL1020X,SDL13GCXA00453,1.1.1.23R4`.
public struct InstrumentIdentity: Sendable, Hashable, Codable {
    public let manufacturer: String
    public let model: String
    public let serial: String
    public let firmware: String

    public init?(idn: String) {
        let parts = idn.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4, !parts[1].isEmpty else { return nil }
        manufacturer = parts[0]; model = parts[1]; serial = parts[2]; firmware = parts[3]
    }

    public init(manufacturer: String, model: String, serial: String, firmware: String) {
        self.manufacturer = manufacturer; self.model = model
        self.serial = serial; self.firmware = firmware
    }

    /// True for the SDL1000X family (SDL1020X, SDL1030X, SDL1020X-E, SDL1030X-E).
    public var isSDL1000X: Bool {
        manufacturer.lowercased().contains("siglent") && model.uppercased().hasPrefix("SDL10")
    }
}
