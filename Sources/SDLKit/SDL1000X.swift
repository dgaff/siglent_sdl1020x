import Foundation
import SCPIKit

/// Typed command interface to a Siglent SDL1000X electronic load.
///
/// All header strings use the short forms from the SDL1000X Programming Guide (E02B) and are
/// verified against hardware by `sdlctl conformance`. Never chain queries with `;` — the SDL
/// concatenates replies without separators.
public final class SDL1000X: Sendable {
    public let connection: SCPIConnection

    public init(connection: SCPIConnection) {
        self.connection = connection
    }

    public convenience init(host: String, port: UInt16 = 5025) {
        self.init(connection: SCPIConnection(host: host, port: port))
    }

    // MARK: - Primitives

    public func write(_ cmd: String) async throws { try await connection.write(cmd) }
    /// Queries retry once on timeout, except `SYST:ERR?` (which is destructive).
    public func query(_ cmd: String) async throws -> String {
        let destructive = cmd.uppercased().hasPrefix("SYST:ERR")
        return try await connection.query(cmd, retries: destructive ? 0 : 1)
    }

    public func queryDouble(_ cmd: String) async throws -> Double {
        let r = try await query(cmd)
        guard let v = SCPIParse.double(r) else { throw SCPIError.invalidResponse(command: cmd, response: r) }
        return v
    }

    public func queryBool(_ cmd: String) async throws -> Bool {
        let r = try await query(cmd)
        guard let v = SCPIParse.bool(r) else { throw SCPIError.invalidResponse(command: cmd, response: r) }
        return v
    }

    public func queryInt(_ cmd: String) async throws -> Int { Int(try await queryDouble(cmd).rounded()) }

    func set(_ header: String, _ value: Double) async throws { try await write("\(header) \(fmt(value))") }
    func set(_ header: String, _ value: Bool) async throws { try await write("\(header) \(value ? "ON" : "OFF")") }
    func set(_ header: String, _ token: String) async throws { try await write("\(header) \(token)") }

    /// Pops all queued errors (`SYST:ERR?` until code 0).
    public func drainErrors(max: Int = 20) async throws -> [(code: Int, message: String)] {
        var out: [(Int, String)] = []
        for _ in 0..<max {
            let r = try await query("SYST:ERR?")
            guard let e = SCPIParse.error(r), e.code != 0 else { break }
            out.append(e)
        }
        return out
    }

    // MARK: - Identity & measurement

    public func identity() async throws -> InstrumentIdentity {
        let r = try await query("*IDN?")
        guard let id = InstrumentIdentity(idn: r) else { throw SCPIError.invalidResponse(command: "*IDN?", response: r) }
        return id
    }

    public func measureVoltage() async throws -> Double { try await queryDouble("MEAS:VOLT?") }
    public func measureCurrent() async throws -> Double { try await queryDouble("MEAS:CURR?") }
    public func measurePower() async throws -> Double { try await queryDouble("MEAS:POW?") }
    public func measureResistance() async throws -> Double { try await queryDouble("MEAS:RES?") }
    public func measureExternal() async throws -> Double { try await queryDouble("MEAS:EXT?") }

    /// All four readings from the instrument (4 round-trips, ~80 ms).
    public func measureAll() async throws -> Reading {
        let v = try await measureVoltage()
        let i = try await measureCurrent()
        let p = try await measurePower()
        let r = try await measureResistance()
        return Reading(voltage: v, current: i, power: p, resistance: r)
    }

    /// V and I only, P/R derived (2 round-trips, ~40 ms). Timestamp is the midpoint.
    public func measureFast() async throws -> Reading {
        let t0 = Date()
        let v = try await measureVoltage()
        let i = try await measureCurrent()
        let mid = Date(timeIntervalSince1970: (t0.timeIntervalSince1970 + Date().timeIntervalSince1970) / 2)
        return .derived(voltage: v, current: i, date: mid)
    }

    public enum WaveQuantity: String, Sendable { case current = "CURR", voltage = "VOLT", power = "POW", resistance = "RES" }

    /// The 200-point waveform-display buffer.
    public func waveData(_ q: WaveQuantity) async throws -> [Double] {
        SCPIParse.doubles(try await connection.query("MEAS:WAVE? \(q.rawValue)", timeout: .seconds(3)))
    }

    // MARK: - Input / short / trigger

    public func inputOn() async throws -> Bool { try await queryBool(":INP?") }
    public func setInput(_ on: Bool) async throws { try await set(":INP", on) }
    public func shortOn() async throws -> Bool { try await queryBool(":SHOR?") }
    public func setShort(_ on: Bool) async throws { try await set(":SHOR", on) }
    public func trigger() async throws { try await write("*TRG") }

    // MARK: - Static (Basic) function

    public func function() async throws -> LoadMode {
        let r = try await query(":FUNC?")
        guard let m = LoadMode(reply: r) else { throw SCPIError.invalidResponse(command: ":FUNC?", response: r) }
        return m
    }
    public func setFunction(_ m: LoadMode) async throws { try await set(":FUNC", m.scpi) }

    public func transientFunction() async throws -> String { try await query(":FUNC:TRAN?") }
    public func setTransientFunction(_ m: LoadMode) async throws {
        precondition(m != .led, "LED has no transient mode")
        try await set(":FUNC:TRAN", m.scpi)
    }

    /// Static set value for a mode (A, V, W, Ω). LED mode has no single level; use `led*`.
    public func level(_ m: LoadMode) async throws -> Double { try await queryDouble("\(m.subsystem)?") }
    public func setLevel(_ m: LoadMode, _ v: Double) async throws { try await set(m.subsystem, v) }

    public func currentRange(_ m: LoadMode) async throws -> CurrentRange { .init(reply: try await queryDouble("\(m.subsystem):IRANG?")) }
    public func setCurrentRange(_ m: LoadMode, _ r: CurrentRange) async throws { try await set("\(m.subsystem):IRANG", r.rawValue) }
    public func voltageRange(_ m: LoadMode) async throws -> VoltageRange { .init(reply: try await queryDouble("\(m.subsystem):VRANG?")) }
    public func setVoltageRange(_ m: LoadMode, _ r: VoltageRange) async throws { try await set("\(m.subsystem):VRANG", r.rawValue) }

    public func resistanceRange() async throws -> ResistanceRange {
        let r = try await query(":RES:RRANG?")
        guard let v = ResistanceRange(reply: r) else { throw SCPIError.invalidResponse(command: ":RES:RRANG?", response: r) }
        return v
    }
    public func setResistanceRange(_ r: ResistanceRange) async throws { try await set(":RES:RRANG", r.rawValue) }

    // CC slew (A/µs)
    public func slewRise() async throws -> Double { try await queryDouble(":CURR:SLEW:POS?") }
    public func setSlewRise(_ v: Double) async throws { try await set(":CURR:SLEW:POS", v) }
    public func slewFall() async throws -> Double { try await queryDouble(":CURR:SLEW:NEG?") }
    public func setSlewFall(_ v: Double) async throws { try await set(":CURR:SLEW:NEG", v) }

    // LED mode
    public func ledVoltage() async throws -> Double { try await queryDouble(":LED:VOLT?") }
    public func setLedVoltage(_ v: Double) async throws { try await set(":LED:VOLT", v) }
    public func ledCurrent() async throws -> Double { try await queryDouble(":LED:CURR?") }
    public func setLedCurrent(_ v: Double) async throws { try await set(":LED:CURR", v) }
    public func ledRco() async throws -> Double { try await queryDouble(":LED:RCONF?") }
    public func setLedRco(_ v: Double) async throws { try await set(":LED:RCONF", v) }

    // MARK: - Transient (Dynamic) settings, per mode (CC/CV/CP/CR)

    public func transientMode(_ m: LoadMode) async throws -> TransientMode {
        let r = try await query("\(m.subsystem):TRAN:MODE?")
        guard let v = TransientMode(reply: r) else { throw SCPIError.invalidResponse(command: "TRAN:MODE?", response: r) }
        return v
    }
    public func setTransientMode(_ m: LoadMode, _ t: TransientMode) async throws { try await set("\(m.subsystem):TRAN:MODE", t.rawValue) }

    public enum TransientParam: String, Sendable, CaseIterable {
        case aLevel = "ALEV", bLevel = "BLEV", aWidth = "AWID", bWidth = "BWID"
    }
    public func transient(_ m: LoadMode, _ p: TransientParam) async throws -> Double { try await queryDouble("\(m.subsystem):TRAN:\(p.rawValue)?") }
    public func setTransient(_ m: LoadMode, _ p: TransientParam, _ v: Double) async throws { try await set("\(m.subsystem):TRAN:\(p.rawValue)", v) }

    public func transientCurrentRange(_ m: LoadMode) async throws -> CurrentRange { .init(reply: try await queryDouble("\(m.subsystem):TRAN:IRANG?")) }
    public func setTransientCurrentRange(_ m: LoadMode, _ r: CurrentRange) async throws { try await set("\(m.subsystem):TRAN:IRANG", r.rawValue) }
    public func transientVoltageRange(_ m: LoadMode) async throws -> VoltageRange { .init(reply: try await queryDouble("\(m.subsystem):TRAN:VRANG?")) }
    public func setTransientVoltageRange(_ m: LoadMode, _ r: VoltageRange) async throws { try await set("\(m.subsystem):TRAN:VRANG", r.rawValue) }

    public func transientSlewRise() async throws -> Double { try await queryDouble(":CURR:TRAN:SLEW:POS?") }
    public func setTransientSlewRise(_ v: Double) async throws { try await set(":CURR:TRAN:SLEW:POS", v) }
    public func transientSlewFall() async throws -> Double { try await queryDouble(":CURR:TRAN:SLEW:NEG?") }
    public func setTransientSlewFall(_ v: Double) async throws { try await set(":CURR:TRAN:SLEW:NEG", v) }

    // MARK: - Battery function

    public func enterBattery() async throws { try await write(":BATT:FUNC") }
    public func inBattery() async throws -> Bool { try await queryBool(":BATT:FUNC?") }
    public func batteryMode() async throws -> BatteryMode {
        let r = try await query(":BATT:MODE?")
        guard let m = BatteryMode(reply: r) else { throw SCPIError.invalidResponse(command: ":BATT:MODE?", response: r) }
        return m
    }
    public func setBatteryMode(_ m: BatteryMode) async throws { try await set(":BATT:MODE", m.rawValue) }
    public func batteryCurrentRange() async throws -> CurrentRange { .init(reply: try await queryDouble(":BATT:IRANG?")) }
    public func setBatteryCurrentRange(_ r: CurrentRange) async throws { try await set(":BATT:IRANG", r.rawValue) }
    public func batteryVoltageRange() async throws -> VoltageRange { .init(reply: try await queryDouble(":BATT:VRANG?")) }
    public func setBatteryVoltageRange(_ r: VoltageRange) async throws { try await set(":BATT:VRANG", r.rawValue) }
    public func batteryResistanceRange() async throws -> ResistanceRange? { ResistanceRange(reply: try await query(":BATT:RRANG?")) }
    public func setBatteryResistanceRange(_ r: ResistanceRange) async throws { try await set(":BATT:RRANG", r.rawValue) }
    public func batteryLevel() async throws -> Double { try await queryDouble(":BATT:LEV?") }
    public func setBatteryLevel(_ v: Double) async throws { try await set(":BATT:LEV", v) }

    /// Cut-off voltage (V), capacity (mAh), time (s) and their enable flags.
    public func batteryStopVoltage() async throws -> Double { try await queryDouble(":BATT:VOLT?") }
    public func setBatteryStopVoltage(_ v: Double) async throws { try await set(":BATT:VOLT", v) }
    public func batteryStopCapacity() async throws -> Double { try await queryDouble(":BATT:CAP?") }
    public func setBatteryStopCapacity(_ v: Double) async throws { try await set(":BATT:CAP", v) }
    public func batteryStopTime() async throws -> Double { try await queryDouble(":BATT:TIM?") }
    public func setBatteryStopTime(_ v: Double) async throws { try await set(":BATT:TIM", v) }
    public func batteryStopVoltageEnabled() async throws -> Bool { try await queryBool(":BATT:VOLT:STAT?") }
    public func setBatteryStopVoltageEnabled(_ on: Bool) async throws { try await set(":BATT:VOLT:STAT", on) }
    public func batteryStopCapacityEnabled() async throws -> Bool { try await queryBool(":BATT:CAP:STAT?") }
    public func setBatteryStopCapacityEnabled(_ on: Bool) async throws { try await set(":BATT:CAP:STAT", on) }
    public func batteryStopTimeEnabled() async throws -> Bool { try await queryBool(":BATT:TIM:STAT?") }
    public func setBatteryStopTimeEnabled(_ on: Bool) async throws { try await set(":BATT:TIM:STAT", on) }

    /// Discharged capacity (mAh) and elapsed time (s) since the battery test started.
    public func batteryDischargedCapacity() async throws -> Double { try await queryDouble(":BATT:DISCHA:CAP?") }
    public func batteryDischargeTime() async throws -> Double { try await queryDouble(":BATT:DISCHA:TIM?") }

    public enum DCRParam: String, Sendable, CaseIterable { case time1 = "TIME1", time2 = "TIME2", current1 = "CURR1", current2 = "CURR2" }
    public func dcr(_ p: DCRParam) async throws -> Double { try await queryDouble(":BATT:DCR:\(p.rawValue)?") }
    public func setDCR(_ p: DCRParam, _ v: Double) async throws { try await set(":BATT:DCR:\(p.rawValue)", v) }
    public func dcrResult() async throws -> Double { try await queryDouble(":BATT:DCR:RES?") }

    // MARK: - List function

    public func enterList() async throws { try await write(":LIST:STAT:ON") }
    public func inList() async throws -> Bool { try await queryBool(":LIST:STAT?") }
    public func listMode() async throws -> LoadMode {
        let r = try await query(":LIST:MODE?")
        guard let m = LoadMode(reply: r) else { throw SCPIError.invalidResponse(command: ":LIST:MODE?", response: r) }
        return m
    }
    public func setListMode(_ m: LoadMode) async throws { try await set(":LIST:MODE", m.scpi) }
    public func listCurrentRange() async throws -> CurrentRange { .init(reply: try await queryDouble(":LIST:IRANG?")) }
    public func setListCurrentRange(_ r: CurrentRange) async throws { try await set(":LIST:IRANG", r.rawValue) }
    public func listVoltageRange() async throws -> VoltageRange { .init(reply: try await queryDouble(":LIST:VRANG?")) }
    public func setListVoltageRange(_ r: VoltageRange) async throws { try await set(":LIST:VRANG", r.rawValue) }
    public func listResistanceRange() async throws -> ResistanceRange? { ResistanceRange(reply: try await query(":LIST:RRANG?")) }
    public func setListResistanceRange(_ r: ResistanceRange) async throws { try await set(":LIST:RRANG", r.rawValue) }
    public func listCount() async throws -> Int { try await queryInt(":LIST:COUN?") }
    public func setListCount(_ n: Int) async throws { try await set(":LIST:COUN", Double(n)) }
    public func listStepCount() async throws -> Int { try await queryInt(":LIST:STEP?") }
    public func setListStepCount(_ n: Int) async throws { try await set(":LIST:STEP", Double(n)) }

    /// Steps are 1-based on the instrument. Reading works in any mode, but **writes are
    /// silently ignored unless the instrument is in List mode** (`enterList()` first).
    public func listStep(_ n: Int) async throws -> ListStep {
        ListStep(level: try await queryDouble(":LIST:LEV? \(n)"),
                 width: try await queryDouble(":LIST:WID? \(n)"),
                 slew: try await queryDouble(":LIST:SLEW? \(n)"))
    }
    public func setListStep(_ n: Int, _ s: ListStep) async throws {
        try await write(":LIST:LEV \(n),\(fmt(s.level))")
        try await write(":LIST:WID \(n),\(fmt(s.width))")
        try await write(":LIST:SLEW \(n),\(fmt(s.slew))")
    }

    /// Currently executing step (List/Program) and whether the sequence has stopped.
    public func testStep() async throws -> Int { try await queryInt(":TEST:STEP?") }
    public func testStopped() async throws -> Bool { try await queryBool(":TEST:STOP?") }

    // MARK: - OCPT / OPPT

    public enum ProtectionTest: String, Sendable, CaseIterable, Identifiable {
        case ocp = "OCP", opp = "OPP"
        public var id: String { rawValue }
        public var label: String { self == .ocp ? "OCPT" : "OPPT" }
        public var unit: String { self == .ocp ? "A" : "W" }
    }
    public enum ProtectionParam: String, Sendable, CaseIterable {
        case start = "STAR", step = "STEP", stepDelay = "STEP:DEL", end = "END", min = "MIN", max = "MAX", voltage = "VOLT"
    }
    public func enterProtectionTest(_ t: ProtectionTest) async throws { try await write(":\(t.rawValue):FUNC") }
    public func inProtectionTest(_ t: ProtectionTest) async throws -> Bool { try await queryBool(":\(t.rawValue):FUNC?") }
    public func protectionTest(_ t: ProtectionTest, _ p: ProtectionParam) async throws -> Double { try await queryDouble(":\(t.rawValue):\(p.rawValue)?") }
    public func setProtectionTest(_ t: ProtectionTest, _ p: ProtectionParam, _ v: Double) async throws { try await set(":\(t.rawValue):\(p.rawValue)", v) }
    public func protectionTestCurrentRange(_ t: ProtectionTest) async throws -> CurrentRange { .init(reply: try await queryDouble(":\(t.rawValue):IRANG?")) }
    public func setProtectionTestCurrentRange(_ t: ProtectionTest, _ r: CurrentRange) async throws { try await set(":\(t.rawValue):IRANG", r.rawValue) }
    public func protectionTestVoltageRange(_ t: ProtectionTest) async throws -> VoltageRange { .init(reply: try await queryDouble(":\(t.rawValue):VRANG?")) }
    public func setProtectionTestVoltageRange(_ t: ProtectionTest, _ r: VoltageRange) async throws { try await set(":\(t.rawValue):VRANG", r.rawValue) }

    // MARK: - Program function

    public func enterProgram() async throws { try await write(":PROG:STAT:ON") }
    public func inProgram() async throws -> Bool { try await queryBool(":PROG:STAT?") }
    public func programStepCount() async throws -> Int { try await queryInt(":PROG:STEP?") }
    public func setProgramStepCount(_ n: Int) async throws { try await set(":PROG:STEP", Double(n)) }

    /// Reads a Program step. LED Io/Rco are read only for LED steps unless `full`.
    public func programStep(_ n: Int, full: Bool = false) async throws -> ProgramStep {
        var s = ProgramStep()
        if let m = LoadMode(reply: try await query(":PROG:MODE? \(n)")) { s.mode = m }
        s.currentRange = .init(reply: try await queryDouble(":PROG:IRANG? \(n)"))
        s.voltageRange = .init(reply: try await queryDouble(":PROG:VRANG? \(n)"))
        if let r = ResistanceRange(reply: try await query(":PROG:RRANG? \(n)")) { s.resistanceRange = r }
        s.short = try await queryBool(":PROG:SHOR? \(n)")
        s.pause = try await queryBool(":PROG:PAUSE? \(n)")
        s.timeOn = try await queryDouble(":PROG:TIME:ON? \(n)")
        s.timeOff = try await queryDouble(":PROG:TIME:OFF? \(n)")
        s.timeDelay = try await queryDouble(":PROG:TIME:DEL? \(n)")
        s.min = try await queryDouble(":PROG:MIN? \(n)")
        s.max = try await queryDouble(":PROG:MAX? \(n)")
        s.level = try await queryDouble(":PROG:LEV? \(n)")
        if s.mode == .led || full {
            s.ledCurrent = try await queryDouble(":PROG:LED:CURR? \(n)")
            s.ledRco = try await queryDouble(":PROG:LED:RCONF? \(n)")
        }
        return s
    }

    /// Writes a Program step. **Ignored by the instrument unless in Program mode**
    /// (`enterProgram()` first).
    public func setProgramStep(_ n: Int, _ s: ProgramStep, full: Bool = false) async throws {
        try await write(":PROG:MODE \(n),\(s.mode.scpi)")
        try await write(":PROG:IRANG \(n),\(fmt(s.currentRange.rawValue))")
        try await write(":PROG:VRANG \(n),\(fmt(s.voltageRange.rawValue))")
        try await write(":PROG:RRANG \(n),\(s.resistanceRange.rawValue)")
        try await write(":PROG:SHOR \(n),\(s.short ? "ON" : "OFF")")
        try await write(":PROG:PAUSE \(n),\(s.pause ? "ON" : "OFF")")
        try await write(":PROG:TIME:ON \(n),\(fmt(s.timeOn))")
        try await write(":PROG:TIME:OFF \(n),\(fmt(s.timeOff))")
        try await write(":PROG:TIME:DEL \(n),\(fmt(s.timeDelay))")
        try await write(":PROG:MIN \(n),\(fmt(s.min))")
        try await write(":PROG:MAX \(n),\(fmt(s.max))")
        try await write(":PROG:LEV \(n),\(fmt(s.level))")
        if s.mode == .led || full {
            try await write(":PROG:LED:CURR \(n),\(fmt(s.ledCurrent))")
            try await write(":PROG:LED:RCONF \(n),\(fmt(s.ledRco))")
        }
    }

    /// Test result for a Program step (raw string; format to be confirmed on hardware).
    public func programResult(_ n: Int) async throws -> String { try await query(":PROG:TEST? \(n)") }

    // MARK: - Utility / protection / system

    /// Break-over voltage (Von) and Von latch.
    public func vOn() async throws -> Double { try await queryDouble(":VOLT:LEV:ON?") }
    public func setVOn(_ v: Double) async throws { try await set(":VOLT:LEV:ON", v) }
    public func vOnLatch() async throws -> Bool { try await queryBool(":VOLT:LATC?") }
    public func setVOnLatch(_ on: Bool) async throws { try await set(":VOLT:LATC", on) }

    public func extInputSwitch() async throws -> Bool { try await queryBool(":EXT:INPUT?") }
    public func setExtInputSwitch(_ on: Bool) async throws { try await set(":EXT:INPUT", on) }

    public enum Protection: String, Sendable { case current = ":CURR:PROT", power = ":POW:PROT" }
    public func protectionEnabled(_ p: Protection) async throws -> Bool { try await queryBool("\(p.rawValue):STAT?") }
    public func setProtectionEnabled(_ p: Protection, _ on: Bool) async throws { try await set("\(p.rawValue):STAT", on) }
    public func protectionLevel(_ p: Protection) async throws -> Double { try await queryDouble("\(p.rawValue):LEV?") }
    public func setProtectionLevel(_ p: Protection, _ v: Double) async throws { try await set("\(p.rawValue):LEV", v) }
    public func protectionDelay(_ p: Protection) async throws -> Double { try await queryDouble("\(p.rawValue):DEL?") }
    public func setProtectionDelay(_ p: Protection, _ v: Double) async throws { try await set("\(p.rawValue):DEL", v) }

    public func sense() async throws -> Bool { try await queryBool("SYST:SENS?") }
    public func setSense(_ on: Bool) async throws { try await set("SYST:SENS", on) }
    public func currentMonitor() async throws -> Bool { try await queryBool("SYSTEM:IMONITOR:STATE?") }
    public func setCurrentMonitor(_ on: Bool) async throws { try await set("SYSTEM:IMONITOR:STATE", on) }
    public func voltageMonitor() async throws -> Bool { try await queryBool("SYSTEM:VMONITOR:STATE?") }
    public func setVoltageMonitor(_ on: Bool) async throws { try await set("SYSTEM:VMONITOR:STATE", on) }
    public func stopOnFail() async throws -> Bool { try await queryBool("STOP:ON:FAIL?") }
    public func setStopOnFail(_ on: Bool) async throws { try await set("STOP:ON:FAIL", on) }

    public func triggerSource() async throws -> TriggerSource {
        let r = try await query("TRIG:SOUR?")
        guard let t = TriggerSource(reply: r) else { throw SCPIError.invalidResponse(command: "TRIG:SOUR?", response: r) }
        return t
    }
    public func setTriggerSource(_ t: TriggerSource) async throws { try await set("TRIG:SOUR", t.rawValue) }

    /// Readback averaging exponent: 2^n points, n in 6...14.
    public func averageExponent() async throws -> Int { try await queryInt("SENS:AVER:COUN?") }
    public func setAverageExponent(_ n: Int) async throws { try await write("SENS:AVER:COUN \(min(max(n, 6), 14))") }

    public func externalMode() async throws -> ExternalMode {
        let r = try await query("EXT:MODE?")
        guard let m = ExternalMode(reply: r) else { throw SCPIError.invalidResponse(command: "EXT:MODE?", response: r) }
        return m
    }
    public func setExternalMode(_ m: ExternalMode) async throws { try await set("EXT:MODE", m.rawValue) }
    public func externalCurrentRange() async throws -> CurrentRange { .init(reply: try await queryDouble("EXT:IRANG?")) }
    public func setExternalCurrentRange(_ r: CurrentRange) async throws { try await set("EXT:IRANG", r.rawValue) }
    public func externalVoltageRange() async throws -> VoltageRange { .init(reply: try await queryDouble("EXT:VRANG?")) }
    public func setExternalVoltageRange(_ r: VoltageRange) async throws { try await set("EXT:VRANG", r.rawValue) }

    // SLMT time measurement
    public func timeTest() async throws -> Bool { try await queryBool("TIME:TEST?") }
    public func setTimeTest(_ on: Bool) async throws { try await set("TIME:TEST", on) }
    public func timeTestLow() async throws -> Double { try await queryDouble("TIME:TEST:VOLT:LOW?") }
    public func setTimeTestLow(_ v: Double) async throws { try await set("TIME:TEST:VOLT:LOW", v) }
    public func timeTestHigh() async throws -> Double { try await queryDouble("TIME:TEST:VOLT:HIGH?") }
    public func setTimeTestHigh(_ v: Double) async throws { try await set("TIME:TEST:VOLT:HIGH", v) }
    public func timeTestRise() async throws -> Double { try await queryDouble("TIME:TEST:RISE?") }
    public func timeTestFall() async throws -> Double { try await queryDouble("TIME:TEST:FALL?") }

    // Waveform display (front panel)
    public func waveWindow() async throws -> Double { try await queryDouble(":WAVE:TIME?") }

    // LAN (read-only in the app)
    public struct LANInfo: Sendable { public var ip, mask, gateway, mac: String; public var dhcp: Bool }
    public func lanInfo() async throws -> LANInfo {
        LANInfo(ip: try await query("LAN:IPAD?"), mask: try await query("LAN:SMAS?"),
                gateway: try await query("LAN:GAT?"), mac: try await query("LAN:MAC?"),
                dhcp: try await queryBool("DHCP?"))
    }
}

/// Compact numeric formatting: up to 6 decimals, no trailing zeros, no exponent.
func fmt(_ v: Double) -> String {
    if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
    var s = String(format: "%.6f", v)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s
}
