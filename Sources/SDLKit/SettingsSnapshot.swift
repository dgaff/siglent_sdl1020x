import Foundation
import SCPIKit

/// Captures and restores user-visible SDL settings, so automated hardware tests leave the
/// instrument exactly as found. Each entry is a query whose raw reply can be written back
/// verbatim to the matching set header.
public struct SettingsSnapshot: Sendable, Codable {
    public struct Entry: Sendable, Codable, Hashable {
        public let query: String
        public let setHeader: String
        /// For indexed settings (List/Program steps): the step number prefix for the set.
        public let index: Int?
        public init(_ query: String, _ setHeader: String, index: Int? = nil) {
            self.query = query; self.setHeader = setHeader; self.index = index
        }
    }

    public var values: [Entry: String] = [:]
    /// List/Program step tables for steps 1...`capturedSteps` (optional for older snapshots).
    public var listSteps: [ListStep]?
    public var programSteps: [ProgramStep]?
    public static let capturedSteps = 10
    public var activeFunction: ActiveFunction = .basic
    public var takenAt = Date()

    public enum ActiveFunction: String, Sendable, Codable { case basic, battery, list, program, ocpt, oppt }

    /// Settings covered by snapshot/restore (static, protection, system, battery, OCP/OPP).
    public static let entries: [Entry] = {
        var e: [Entry] = []
        for m in LoadMode.allCases {
            if m != .led { e.append(.init("\(m.subsystem)?", m.subsystem)) }
            e.append(.init("\(m.subsystem):IRANG?", "\(m.subsystem):IRANG"))
            e.append(.init("\(m.subsystem):VRANG?", "\(m.subsystem):VRANG"))
            if m != .led {
                e.append(.init("\(m.subsystem):TRAN:MODE?", "\(m.subsystem):TRAN:MODE"))
                e.append(.init("\(m.subsystem):TRAN:IRANG?", "\(m.subsystem):TRAN:IRANG"))
                e.append(.init("\(m.subsystem):TRAN:VRANG?", "\(m.subsystem):TRAN:VRANG"))
                for p in SDL1000X.TransientParam.allCases {
                    e.append(.init("\(m.subsystem):TRAN:\(p.rawValue)?", "\(m.subsystem):TRAN:\(p.rawValue)"))
                }
            }
        }
        e += [
            .init(":RES:RRANG?", ":RES:RRANG"),
            .init(":RES:TRAN:RRANG?", ":RES:TRAN:RRANG"),
            .init(":CURR:SLEW:POS?", ":CURR:SLEW:POS"),
            .init(":CURR:SLEW:NEG?", ":CURR:SLEW:NEG"),
            .init(":CURR:TRAN:SLEW:POS?", ":CURR:TRAN:SLEW:POS"),
            .init(":CURR:TRAN:SLEW:NEG?", ":CURR:TRAN:SLEW:NEG"),
            .init(":LED:VOLT?", ":LED:VOLT"),
            .init(":LED:CURR?", ":LED:CURR"),
            .init(":LED:RCONF?", ":LED:RCONF"),
            // Battery
            .init(":BATT:MODE?", ":BATT:MODE"),
            .init(":BATT:IRANG?", ":BATT:IRANG"),
            .init(":BATT:VRANG?", ":BATT:VRANG"),
            .init(":BATT:RRANG?", ":BATT:RRANG"),
            .init(":BATT:LEV?", ":BATT:LEV"),
            .init(":BATT:VOLT?", ":BATT:VOLT"),
            .init(":BATT:CAP?", ":BATT:CAP"),
            .init(":BATT:TIM?", ":BATT:TIM"),
            .init(":BATT:VOLT:STAT?", ":BATT:VOLT:STAT"),
            .init(":BATT:CAP:STAT?", ":BATT:CAP:STAT"),
            .init(":BATT:TIM:STAT?", ":BATT:TIM:STAT"),
            .init(":BATT:DCR:TIME1?", ":BATT:DCR:TIME1"),
            .init(":BATT:DCR:TIME2?", ":BATT:DCR:TIME2"),
            .init(":BATT:DCR:CURR1?", ":BATT:DCR:CURR1"),
            .init(":BATT:DCR:CURR2?", ":BATT:DCR:CURR2"),
            // List (header only; steps captured separately)
            .init(":LIST:MODE?", ":LIST:MODE"),
            .init(":LIST:IRANG?", ":LIST:IRANG"),
            .init(":LIST:VRANG?", ":LIST:VRANG"),
            .init(":LIST:RRANG?", ":LIST:RRANG"),
            .init(":LIST:COUN?", ":LIST:COUN"),
            .init(":LIST:STEP?", ":LIST:STEP"),
            .init(":PROG:STEP?", ":PROG:STEP"),
            // Utility / protection / system
            .init(":VOLT:LEV:ON?", ":VOLT:LEV:ON"),
            .init(":VOLT:LATC?", ":VOLT:LATC"),
            .init(":EXT:INPUT?", ":EXT:INPUT"),
            .init(":CURR:PROT:STAT?", ":CURR:PROT:STAT"),
            .init(":CURR:PROT:LEV?", ":CURR:PROT:LEV"),
            .init(":CURR:PROT:DEL?", ":CURR:PROT:DEL"),
            .init(":POW:PROT:STAT?", ":POW:PROT:STAT"),
            .init(":POW:PROT:LEV?", ":POW:PROT:LEV"),
            .init(":POW:PROT:DEL?", ":POW:PROT:DEL"),
            .init("SYST:SENS?", "SYST:SENS"),
            .init("SYSTEM:IMONITOR:STATE?", "SYSTEM:IMONITOR:STATE"),
            .init("SYSTEM:VMONITOR:STATE?", "SYSTEM:VMONITOR:STATE"),
            .init("STOP:ON:FAIL?", "STOP:ON:FAIL"),
            .init("TRIG:SOUR?", "TRIG:SOUR"),
            .init("SENS:AVER:COUN?", "SENS:AVER:COUN"),
            .init("EXT:MODE?", "EXT:MODE"),
            .init("EXT:IRANG?", "EXT:IRANG"),
            .init("EXT:VRANG?", "EXT:VRANG"),
            .init("TIME:TEST?", "TIME:TEST"),
            .init("TIME:TEST:VOLT:LOW?", "TIME:TEST:VOLT:LOW"),
            .init("TIME:TEST:VOLT:HIGH?", "TIME:TEST:VOLT:HIGH"),
        ]
        for t in SDL1000X.ProtectionTest.allCases {
            e.append(.init(":\(t.rawValue):IRANG?", ":\(t.rawValue):IRANG"))
            e.append(.init(":\(t.rawValue):VRANG?", ":\(t.rawValue):VRANG"))
            for p in SDL1000X.ProtectionParam.allCases {
                e.append(.init(":\(t.rawValue):\(p.rawValue)?", ":\(t.rawValue):\(p.rawValue)"))
            }
        }
        return e
    }()

    /// Read-only queries that should always answer (for conformance checks), beyond `entries`.
    public static let readOnlyQueries: [String] = [
        "*IDN?", ":INP?", ":SHOR?", ":FUNC?", ":FUNC:TRAN?",
        "MEAS:VOLT?", "MEAS:CURR?", "MEAS:POW?", "MEAS:RES?", "MEAS:EXT?",
        ":BATT:FUNC?", ":BATT:DISCHA:CAP?", ":BATT:DISCHA:TIM?", ":BATT:DCR:RES?",
        ":LIST:STAT?", ":PROG:STAT?", ":OCP:FUNC?", ":OPP:FUNC?",
        ":TEST:STEP?", ":TEST:STOP?", ":WAVE:TIME?", ":WAVE:MODE?", ":WAVE:PAUSE?", ":WAVE:DISP?",
        "TIME:TEST:RISE?", "TIME:TEST:FALL?",
        ":LIST:LEV? 1", ":LIST:WID? 1", ":LIST:SLEW? 1",
        ":PROG:MODE? 1", ":PROG:IRANG? 1", ":PROG:VRANG? 1", ":PROG:RRANG? 1", ":PROG:SHOR? 1",
        ":PROG:PAUSE? 1", ":PROG:TIME:ON? 1", ":PROG:TIME:OFF? 1", ":PROG:TIME:DEL? 1",
        ":PROG:MIN? 1", ":PROG:MAX? 1", ":PROG:LEV? 1", ":PROG:LED:CURR? 1", ":PROG:LED:RCONF? 1",
        ":PROG:TEST? 1",
        "LAN:LINK?", "DHCP?", "LAN:IPAD?", "LAN:SMAS?", "LAN:GAT?", "LAN:MAC?",
        "*ESE?", "*SRE?", "*STB?",
    ]

    /// Takes a snapshot. Entries that fail to answer are recorded as missing (not fatal).
    public static func take(from sdl: SDL1000X) async throws -> SettingsSnapshot {
        var s = SettingsSnapshot()
        if try await sdl.inBattery() { s.activeFunction = .battery }
        else if try await sdl.inList() { s.activeFunction = .list }
        else if try await sdl.inProgram() { s.activeFunction = .program }
        else if try await sdl.inProtectionTest(.ocp) { s.activeFunction = .ocpt }
        else if try await sdl.inProtectionTest(.opp) { s.activeFunction = .oppt }
        for e in entries {
            if let r = try? await sdl.query(e.query) { s.values[e] = r }
        }
        s.values[Entry(":FUNC?", ":FUNC")] = try await sdl.query(":FUNC?")
        // Step tables are readable in any mode.
        var ls: [ListStep] = [], ps: [ProgramStep] = []
        for n in 1...capturedSteps {
            ls.append(try await sdl.listStep(n))
            ps.append(try await sdl.programStep(n, full: true))
        }
        s.listSteps = ls
        s.programSteps = ps
        return s
    }

    /// Restores captured values, then re-enters the function that was active.
    /// Only settings that differ are written (each SDL write takes ~200 ms). Forces input OFF.
    public func restore(to sdl: SDL1000X) async throws {
        if try await sdl.inputOn() { try await sdl.setInput(false) }
        // Some pairs are kept ordered by clamping (min ≤ max, start ≤ end), so one pass in a
        // fixed order can leave a value clamped; repeat until a re-read matches (≤ 3 passes).
        for _ in 0..<3 {
            let changed = Set(try await diff(against: sdl).map(\.0))
            if changed.isEmpty { break }
            try await writePass(changed, to: sdl)
        }
        try await reenterFunction(sdl)
    }

    private func writePass(_ changed: Set<Entry>, to sdl: SDL1000X) async throws {
        // Ranges first: levels are clamped to the active range.
        func rank(_ e: Entry) -> Int { e.setHeader.contains("RANG") ? 0 : 1 }
        let ordered = values.filter { changed.contains($0.key) && $0.key.query != ":FUNC?" }
            .sorted { (rank($0.key), $0.key.query) < (rank($1.key), $1.key.query) }
        for (e, value) in ordered {
            let v = value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            try await sdl.write("\(e.setHeader) \(v)")
        }
        // Step edits are only accepted while in the matching mode.
        if let saved = listSteps {
            var entered = false
            for (i, step) in saved.enumerated() where !(try await sdl.listStep(i + 1)).sameValues(as: step) {
                if !entered { try await sdl.enterList(); entered = true }
                try await sdl.setListStep(i + 1, step)
            }
        }
        if let saved = programSteps {
            var entered = false
            for (i, step) in saved.enumerated() where !(try await sdl.programStep(i + 1, full: true)).sameValues(as: step) {
                if !entered { try await sdl.enterProgram(); entered = true }
                try await sdl.setProgramStep(i + 1, step, full: true)
            }
        }
    }

    private func reenterFunction(_ sdl: SDL1000X) async throws {
        switch activeFunction {
        case .basic:
            if let f = values[Entry(":FUNC?", ":FUNC")] { try await sdl.write(":FUNC \(f)") }
        case .battery: try await sdl.enterBattery()
        case .list: try await sdl.enterList()
        case .program: try await sdl.enterProgram()
        case .ocpt: try await sdl.enterProtectionTest(.ocp)
        case .oppt: try await sdl.enterProtectionTest(.opp)
        }
    }

    /// Entries whose current value differs from the snapshot.
    public func diff(against sdl: SDL1000X) async throws -> [(Entry, String, String)] {
        var out: [(Entry, String, String)] = []
        for (e, old) in values {
            let new = (try? await sdl.query(e.query)) ?? "<no reply>"
            if !Self.equivalent(old, new, query: e.query) { out.append((e, old, new)) }
        }
        for (i, step) in (listSteps ?? []).enumerated() {
            let now = try await sdl.listStep(i + 1)
            if !now.sameValues(as: step) {
                out.append((Entry(":LIST step \(i + 1)", ""), step.summary, now.summary))
            }
        }
        for (i, step) in (programSteps ?? []).enumerated() {
            let now = try await sdl.programStep(i + 1, full: true)
            if !now.sameValues(as: step) {
                out.append((Entry(":PROG step \(i + 1)", ""), step.summary, now.summary))
            }
        }
        return out.sorted { $0.0.query < $1.0.query }
    }

    /// Settings whose factory value lies below the minimum the instrument accepts over SCPI,
    /// so a restore lands on the minimum instead (observed on fw 1.1.1.23R4).
    static let clampedMinimums: [String: Double] = [":BATT:DCR:TIME1?": 0.02, ":BATT:DCR:TIME2?": 0.02]

    static func equivalent(_ a: String, _ b: String, query: String = "") -> Bool {
        if a == b { return true }
        if let minimum = clampedMinimums[query], let x = SCPIParse.double(a), let y = SCPIParse.double(b),
           x < minimum, abs(y - minimum) < 1e-6 { return true }
        if let x = SCPIParse.double(a), let y = SCPIParse.double(b) { return abs(x - y) <= max(1e-6, abs(x) * 1e-6) }
        return a.uppercased() == b.uppercased()
    }
}
