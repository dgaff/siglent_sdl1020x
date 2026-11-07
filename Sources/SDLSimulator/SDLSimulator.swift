import Foundation
import Network
import SCPIKit

/// A fake SDL1000X reachable over TCP, reproducing the real instrument's observable quirks:
///
/// - Unknown/malformed queries get **no reply** (and queue `-113,Undefined header`).
/// - Chained queries (`A?;B?`) reply concatenated with **no separator**, one `\n` at the end.
/// - Float replies are `%.6f`; ranges are bare integers; `:WAVE:TIME?` has an `s` suffix.
///
/// Electrical model: an ideal voltage source `sourceVoltage` with series `sourceResistance`
/// connected to the load input. Battery mode integrates capacity and honors the stop
/// conditions. Optionally the source voltage sags with discharged capacity (`batteryModel`).
public final class SDLSimulator: @unchecked Sendable {
    public struct BatteryModel: Sendable {
        public var capacity_mAh: Double
        public var fullVoltage: Double
        public var emptyVoltage: Double
        public init(capacity_mAh: Double, fullVoltage: Double, emptyVoltage: Double) {
            self.capacity_mAh = capacity_mAh; self.fullVoltage = fullVoltage; self.emptyVoltage = emptyVoltage
        }
        /// Crude Li-ion-ish OCV curve: steep at both ends, plateau in between.
        func ocv(dischargedFraction f: Double) -> Double {
            let x = min(max(f, 0), 1)
            let shape = 0.15 * (1 - x) + 0.7 * (1 - x) * 0.5 + 0.15 * pow(1 - x, 8)
            let norm = shape / (0.15 + 0.35 + 0.15)
            return emptyVoltage + (fullVoltage - emptyVoltage) * (0.2 + 0.8 * norm) - (x >= 1 ? 0.5 : 0)
        }
    }

    public let identity = "Siglent Technologies,SDL1020X,SIM0000000001,1.1.1.23R4"
    public private(set) var port: UInt16 = 0

    // Electrical environment (set via API or SIM:* commands)
    public var sourceVoltage: Double { get { sync { _sourceVoltage } } set { sync { _sourceVoltage = newValue } } }
    public var sourceResistance: Double { get { sync { _sourceResistance } } set { sync { _sourceResistance = newValue } } }
    public var batteryModel: BatteryModel? { get { sync { _battery } } set { sync { _battery = newValue } } }
    /// Processing time per query / per set command. The real SDL takes ~10 ms per query but
    /// ~200 ms per set command, and processes commands strictly in order, so a burst of
    /// writes delays every later reply. Defaults are small to keep tests fast.
    public var queryCost: Double = 0.002
    public var writeCost: Double = 0.002
    /// When the simulated command processor is next free.
    private var busyUntil = DispatchTime.now()

    private var _sourceVoltage = 0.0
    private var _sourceResistance = 0.05
    /// Source current limit (like a bench supply's CC limit, or a DUT's over-current
    /// protection): above it the source collapses. nil = unlimited.
    private var _sourceCurrentLimit: Double?
    private var _battery: BatteryModel?

    private let queue = DispatchQueue(label: "SDLSimulator")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var commands: [(SCPIPattern, Handler)] = []
    private var settings: [String: String] = [:]
    private var errors: [String] = []
    private var timer: DispatchSourceTimer?

    // Dynamic state
    private var inputOn = false
    private var shortOn = false
    private var activeFunction = "BASIC"       // BASIC, BATTERY, LIST, PROGRAM, OCP, OPP
    /// Dynamic (transient) operation active; not observable via SCPI on the real device.
    private var dynamicActive = false
    private var dynamicEpoch = Date()
    // List / Program / OCPT / OPPT runs (behaviour measured on hardware, see hardware-notes):
    // input ON arms List/Program (step 0) and a BUS trigger starts them; OCP/OPP start at
    // input ON. All switch the input off at the end.
    private var seqStart: Date?
    private var seqStep = 0
    private var programResults: [Int: Double] = [:]
    private var programMeasured: Set<Int> = []
    private var dischargedmAh = 0.0
    private var dischargeSeconds = 0.0
    private var lastTick = Date()

    typealias Handler = (_ args: [String], _ isQuery: Bool) -> String?

    public init() {
        queue.setSpecific(key: queueKey, value: true)
        registerCommands()
    }

    private func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return queue.sync(execute: body)
    }

    // MARK: - Server lifecycle

    /// Starts listening (port 0 = ephemeral). Returns the bound port.
    @discardableResult
    public func start(port: UInt16 = 0) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let bound: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = LockedOnce()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        self.port = bound
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        lastTick = Date()
        return bound
    }

    public func stop() {
        sync {
            timer?.cancel(); timer = nil
            listener?.cancel(); listener = nil
            for c in connections.values { c.cancel() }
            connections.removeAll()
        }
    }

    /// Number of connected clients (the real SDL allows one).
    public var clientCount: Int { sync { connections.count } }

    /// Drops all client connections (to test reconnect logic).
    public func dropClients() {
        sync { for c in connections.values { c.cancel() }; connections.removeAll() }
    }

    private func accept(_ c: NWConnection) {
        // Real SDL: one client at a time; extra connections are accepted then closed at once.
        if !connections.isEmpty {
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 0.02) { c.cancel() }
            return
        }
        let id = ObjectIdentifier(c)
        connections[id] = c
        buffers[id] = Data()
        c.stateUpdateHandler = { [weak self] s in
            if case .cancelled = s { self?.connections[id] = nil }
            if case .failed = s { self?.connections[id] = nil }
        }
        c.start(queue: queue)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            let id = ObjectIdentifier(c)
            if let data { self.buffers[id, default: Data()].append(data) }
            while let nl = self.buffers[id]?.firstIndex(of: 0x0A) {
                let line = String(decoding: self.buffers[id]![..<nl], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                self.buffers[id]!.removeSubrange(...nl)
                let units = SCPIMessage.split(line: line)
                let cost = units.reduce(0.0) { $0 + ($1.isQuery ? self.queryCost : self.writeCost) }
                self.busyUntil = max(self.busyUntil, .now()) + cost
                if let reply = self.execute(line: line) {
                    self.queue.asyncAfter(deadline: self.busyUntil) {
                        // Real SDL quirk: error-queue entries (non-zero code) end with "\n\n".
                        let errorEntry = line.uppercased().hasPrefix("SYST:ERR") && reply.hasPrefix("-")
                        c.send(content: Data((reply + (errorEntry ? "\n\n" : "\n")).utf8), completion: .contentProcessed { _ in })
                    }
                }
            }
            if done || err != nil { c.cancel(); return }
            self.receive(c)
        }
    }

    // MARK: - Command execution

    /// Executes one line; returns the reply line (without `\n`) or nil if nothing to send.
    public func execute(line: String) -> String? {
        sync {
            var replies: [String] = []
            for msg in SCPIMessage.split(line: line) {
                if msg.header.uppercased().hasPrefix("SIM:") {
                    if let r = simCommand(msg) { replies.append(r) }
                    continue
                }
                guard let (_, handler) = commands.first(where: { $0.0.matches(header: msg.header) }) else {
                    errors.append("-113,Undefined header,\(msg.header)")
                    // Real SDL: silent. Abandon the rest of the line too.
                    return replies.isEmpty ? nil : replies.joined()
                }
                if let r = handler(msg.arguments, msg.isQuery), msg.isQuery { replies.append(r) }
            }
            return replies.isEmpty ? nil : replies.joined()
        }
    }

    private func simCommand(_ m: SCPIMessage) -> String? {
        let h = m.header.uppercased()
        let v = m.arguments.first.flatMap(Double.init)
        switch h {
        case "SIM:SOURCE:VOLT": if let v { _sourceVoltage = v }
        case "SIM:SOURCE:VOLT?": return f6(_sourceVoltage)
        case "SIM:SOURCE:RES": if let v { _sourceResistance = v }
        case "SIM:SOURCE:ILIM": _sourceCurrentLimit = v.flatMap { $0 > 0 ? $0 : nil }
        case "SIM:OCP:STALL": ocpStall = (v ?? 0) > 0      // OCPT/OPPT never end (hardware oddity)
        case "SIM:BATTERY":
            // SIM:BATTERY <capacity_mAh>,<full V>,<empty V>  |  SIM:BATTERY OFF
            if m.arguments.count == 3, let c = Double(m.arguments[0]), let fv = Double(m.arguments[1]), let ev = Double(m.arguments[2]) {
                _battery = BatteryModel(capacity_mAh: c, fullVoltage: fv, emptyVoltage: ev)
                _sourceVoltage = fv
                batteryDrawn_mAh = 0      // a fresh, full cell
            } else { _battery = nil }
        default: break
        }
        return nil
    }

    // MARK: - Physics

    /// Current drawn and terminal voltage for the present state.
    private func operatingPoint() -> (v: Double, i: Double) {
        advanceSequence()
        let p = rawOperatingPoint()
        // OCPT/OPPT: the instrument ends the test when the voltage falls below the threshold.
        if inputOn, seqStart != nil, activeFunction == "OCP" || activeFunction == "OPP",
           p.v < dbl(":\(activeFunction):VOLT") {
            inputOn = false; seqStart = nil
            return (_sourceVoltage, 0)
        }
        return p
    }

    private func rawOperatingPoint() -> (v: Double, i: Double) {
        let vs = _sourceVoltage, rs = max(_sourceResistance, 1e-4)
        guard inputOn else { return (vs, 0) }
        if activeFunction == "LIST" || activeFunction == "PROGRAM", seqStart == nil { return (vs, 0) }  // armed
        if activeFunction == "PROGRAM", seqLoadOff { return (vs, 0) }
        let von = dbl(":VOLT:LEV:ON")
        if vs <= von && von > 0 { return (vs, 0) }
        if shortOn { let i = min(vs / rs, iMax()); return (vs - i * rs, i) }
        let mode = currentStaticMode()
        var i: Double
        switch mode {
        case "CURRENT": i = level(for: "CURRENT")
        case "VOLTAGE":
            let vset = level(for: "VOLTAGE")
            i = vs > vset ? (vs - vset) / rs : 0
        case "POWER":
            let p = level(for: "POWER")
            let disc = vs * vs - 4 * rs * p
            i = disc >= 0 ? (vs - disc.squareRoot()) / (2 * rs) : vs / (2 * rs)
        case "RESISTANCE":
            let r = max(level(for: "RESISTANCE"), 1e-3)
            i = vs / (r + rs)
        default: // LED: crude — conducts above Vo
            let vo = dbl(":LED:VOLT")
            i = vs > vo ? min(dbl(":LED:CURR"), (vs - vo) / rs) : 0
        }
        i = min(max(i, 0), vs / rs, iMax())
        if let lim = _sourceCurrentLimit, i > lim { return (0.2, lim) }   // source collapses
        return (vs - i * rs, i)
    }

    // MARK: - Sequences (List / Program / OCPT / OPPT)

    private var seqLoadOff = false
    private var ocpStall = false

    /// Advances the running sequence to the current time (step, level, end).
    private func advanceSequence() {
        guard inputOn, let start = seqStart else { return }
        let e = Date().timeIntervalSince(start)
        switch activeFunction {
        case "LIST":
            let n = max(1, Int(dbl(":LIST:STEP"))), count = max(1, Int(dbl(":LIST:COUN")))
            let widths = (1...n).map { dbl(":LIST:WID#\($0)", default: dbl(":LIST:WID")) }
            let cycle = max(widths.reduce(0, +), 1e-3)
            if e >= cycle * Double(count) { inputOn = false; seqStart = nil; seqStep = n + 1; return }
            var r = e.truncatingRemainder(dividingBy: cycle)
            for (k, w) in widths.enumerated() {
                if r < w { seqStep = k + 1; break }
                r -= w
            }
        case "PROGRAM":
            let n = max(1, Int(dbl(":PROG:STEP")))
            var t = 0.0
            for k in 1...n {
                let on = dbl(":PROG:TIME:ON#\(k)", default: 1), off = dbl(":PROG:TIME:OFF#\(k)", default: 1)
                let delay = dbl(":PROG:TIME:DEL#\(k)", default: 1)
                if e < t + on {
                    seqStep = k; seqLoadOff = false
                    if e >= t + min(delay, on), !programMeasured.contains(k) {
                        programMeasured.insert(k)
                        let p = rawOperatingPoint()
                        programResults[k] = (settings[":PROG:MODE#\(k)"] ?? "CURRENT") == "VOLTAGE" ? p.i : p.v
                    }
                    return
                }
                if k == n { break }
                if e < t + on + off { seqStep = k; seqLoadOff = true; return }
                t += on + off
            }
            inputOn = false; seqStart = nil; seqLoadOff = false
        case "OCP", "OPP":
            let t = activeFunction
            let stepDelay = max(dbl(":\(t):STEP:DEL"), 0.01)
            let level = dbl(":\(t):STAR") + dbl(":\(t):STEP") * (e / stepDelay).rounded(.down)
            if level > dbl(":\(t):END") + 1e-9, !ocpStall { inputOn = false; seqStart = nil }
            seqStep = 1
        default: break
        }
    }

    private func sequenceLevel(_ mode: String) -> Double? {
        guard let start = seqStart else { return nil }
        switch activeFunction {
        case "LIST": return dbl(":LIST:LEV#\(max(seqStep, 1))", default: dbl(":LIST:LEV"))
        case "PROGRAM": return dbl(":PROG:LEV#\(max(seqStep, 1))", default: 1)
        case "OCP", "OPP":
            let t = activeFunction
            let e = Date().timeIntervalSince(start)
            return min(dbl(":\(t):STAR") + dbl(":\(t):STEP") * (e / max(dbl(":\(t):STEP:DEL"), 0.01)).rounded(.down), dbl(":\(t):END"))
        default: return nil
        }
    }

    private func iMax() -> Double { 30 }

    private func currentStaticMode() -> String {
        switch activeFunction {
        case "LIST": return settings[":LIST:MODE"] ?? "CURRENT"
        case "PROGRAM": return settings[":PROG:MODE#\(max(seqStep, 1))"] ?? settings[":PROG:MODE"] ?? "CURRENT"
        case "OCP": return "CURRENT"
        case "OPP": return "POWER"
        case "BATTERY": return settings[":BATT:MODE"] ?? "CURRENT"
        default: return settings[":FUNC"] ?? "CURRENT"
        }
    }

    private func level(for mode: String) -> Double {
        if activeFunction == "BATTERY" { return dbl(":BATT:LEV") }
        if let l = sequenceLevel(mode) { return l }
        if dynamicActive {
            // Continuous transient: A for AWID seconds, then B for BWID seconds, repeating.
            let key = [("CURRENT", ":CURR"), ("VOLTAGE", ":VOLT"), ("POWER", ":POW"), ("RESISTANCE", ":RES")]
                .first { $0.0 == mode }?.1 ?? ":CURR"
            let a = dbl("\(key):TRAN:AWID"), b = dbl("\(key):TRAN:BWID")
            let phase = Date().timeIntervalSince(dynamicEpoch).truncatingRemainder(dividingBy: max(a + b, 1e-3))
            return dbl(phase < a ? "\(key):TRAN:ALEV" : "\(key):TRAN:BLEV")
        }
        switch mode {
        case "CURRENT": return dbl(":CURR")
        case "VOLTAGE": return dbl(":VOLT")
        case "POWER": return dbl(":POW")
        default: return dbl(":RES")
        }
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard inputOn else { return }
        let (v, i) = operatingPoint()
        if activeFunction == "BATTERY" {
            dischargedmAh += i * dt / 3.6
            // Measured: with the load held off (source below Von) the test pauses: the timer
            // stops and V_Stop is not checked, so the input stays ON (hardware-notes).
            let sinking = i > 0
            if sinking { dischargeSeconds += dt }
            let vStop = sinking && bool(":BATT:VOLT:STAT") && v <= dbl(":BATT:VOLT")
            let cStop = bool(":BATT:CAP:STAT") && dischargedmAh >= dbl(":BATT:CAP")
            let tStop = bool(":BATT:TIM:STAT") && dischargeSeconds >= dbl(":BATT:TIM")
            if vStop || cStop || tStop { inputOn = false }
        }
        if let b = _battery {
            // Track total charge drawn from the modeled battery regardless of function.
            batteryDrawn_mAh += i * dt / 3.6
            _sourceVoltage = b.ocv(dischargedFraction: batteryDrawn_mAh / b.capacity_mAh)
        }
    }
    private var batteryDrawn_mAh = 0.0

    // MARK: - Settings storage helpers

    private func dbl(_ key: String) -> Double { Double(settings[key] ?? "") ?? 0 }
    private func dbl(_ key: String, default d: Double) -> Double { Double(settings[key] ?? "") ?? d }
    private func bool(_ key: String) -> Bool { settings[key] == "1" }

    private func f6(_ v: Double) -> String { String(format: "%.6f", v) }

    private enum Kind {
        case double(Double), range(Double, threshold: Double, low: Double, high: Double)
        case enumeration([String], String), bool(Bool), int(Int)
    }

    /// Registers a stored setting with set + query forms.
    private func setting(_ pattern: String, key: String, _ kind: Kind, indexed: Bool = false) {
        switch kind {
        case .double(let d): settings[key] = f6(d)
        case .range(let d, _, _, _): settings[key] = String(Int(d))
        case .enumeration(_, let d): settings[key] = d
        case .bool(let b): settings[key] = b ? "1" : "0"
        case .int(let n): settings[key] = String(n)
        }
        let normalize: (String) -> String? = { [unowned self] arg in
            let a = arg.uppercased()
            switch kind {
            case .double:
                if a.hasPrefix("MIN") { return self.f6(0) }
                if a.hasPrefix("MAX") || a.hasPrefix("DEF") { return self.settings[key] }
                return Double(a).map(self.f6)
            case .range(_, let thr, let lo, let hi):
                guard let v = Double(a) else { return nil }
                return String(Int(v > thr ? hi : lo))
            case .enumeration(let opts, _):
                return opts.first { $0.hasPrefix(String(a.prefix(3))) }
            case .bool:
                if a == "ON" || a == "1" { return "1" }
                if a == "OFF" || a == "0" { return "0" }
                return nil
            case .int:
                return Double(a).map { String(Int($0.rounded())) }
            }
        }
        commands.append((SCPIPattern(pattern), { [unowned self] args, _ in
            if indexed, let a = args.first, let v = args.dropFirst().first, let s = Int(a), let n = normalize(v) {
                if let n = adjust(key: key, value: n, index: s) { settings["\(key)#\(s)"] = n }
            } else if !indexed, let a = args.first, let n = normalize(a) {
                if let n = adjust(key: key, value: n) { settings[key] = n }
            } else {
                errors.append("-224,Illegal parameter value")
            }
            return nil
        }))
        commands.append((SCPIPattern(pattern + "?"), { [unowned self] args, _ in
            if indexed {
                guard let a = args.first, let s = Int(a) else { return nil }
                if let v = settings["\(key)#\(s)"] { return v }
                return settings[key]
            }
            return settings[key]
        }))
    }

    /// Mirrors the real instrument's handling of edits (see docs/hardware-notes.md):
    /// step-table edits outside List/Program mode are ignored; out-of-range values are mostly
    /// clamped to the limit, except a CR level below minimum, which is ignored.
    /// Returns the value to store, or nil to ignore the write.
    private func adjust(key: String, value: String, index: Int? = nil) -> String? {
        if key.hasPrefix(":LIST:"), ["LEV", "WID", "SLEW"].contains(where: { key.hasSuffix($0) }) {
            return activeFunction == "LIST" ? value : nil
        }
        if key.hasPrefix(":PROG:"), key != ":PROG:STEP" { guard activeFunction == "PROGRAM" else { return nil } }
        guard let v = Double(value) else { return value }
        // Measured: pairs are kept ordered by clamping the value being written.
        let suffix = index.map { "#\($0)" } ?? ""
        func other(_ k: String) -> Double { Double(settings[k + suffix] ?? settings[k] ?? "") ?? v }
        switch key {
        case ":PROG:MIN": return f6(min(v, other(":PROG:MAX")))
        case ":PROG:MAX": return f6(max(v, other(":PROG:MIN")))
        case ":OCP:MIN", ":OPP:MIN": return f6(min(v, other(key.replacingOccurrences(of: "MIN", with: "MAX"))))
        case ":OCP:MAX", ":OPP:MAX": return f6(max(v, other(key.replacingOccurrences(of: "MAX", with: "MIN"))))
        case ":OCP:END", ":OPP:END": return f6(max(v, other(key.replacingOccurrences(of: "END", with: "STAR"))))
        case ":OCP:STAR", ":OPP:STAR": return f6(min(v, other(key.replacingOccurrences(of: "STAR", with: "END"))))
        default: break
        }
        if key.hasPrefix(":PROG:") { return value }
        func clamp(_ lo: Double, _ hi: Double) -> String { f6(min(max(v, lo), hi)) }
        switch key {
        case ":CURR:SLEW:POS", ":CURR:SLEW:NEG", ":CURR:SLEW:BOTH":
            return clamp(0.001, dbl(":CURR:IRANG") > 5 ? 2.5 : 0.5)
        case ":CURR:TRAN:SLEW:POS", ":CURR:TRAN:SLEW:NEG":
            return clamp(0.001, dbl(":CURR:TRAN:IRANG") > 5 ? 2.5 : 0.5)
        case ":VOLT:TRAN:AWID", ":VOLT:TRAN:BWID": return clamp(1, 999)
        case ":CURR": return clamp(0, dbl(":CURR:IRANG"))
        case ":RES": return v < 0.03 ? nil : clamp(0.03, 10_000)
        case ":POW": return clamp(0, 200)
        case ":LIST:STEP": return String(Int(min(max(v, 1), 100)))
        case ":PROG:STEP": return String(Int(min(max(v, 1), 50)))
        default: return value
        }
    }

    private func command(_ pattern: String, _ h: @escaping Handler) {
        commands.append((SCPIPattern(pattern), h))
    }

    // MARK: - Command table

    private func registerCommands() {
        let modes = ["CURRENT", "VOLTAGE", "POWER", "RESISTANCE", "LED"]
        let rr = ["LOW", "MIDDLE", "HIGH", "UPPER"]
        let tmode = ["CONTINUOUS", "PULSE", "TOGGLE"]
        let iR = Kind.range(5, threshold: 5, low: 5, high: 30)
        let vR = Kind.range(36, threshold: 36, low: 36, high: 150)

        command("*IDN?") { [unowned self] _, _ in identity }
        command("*RST") { _, _ in nil }
        command("*CLS") { [unowned self] _, _ in errors.removeAll(); return nil }
        command("*OPC?") { _, _ in "1" }
        command("*ESE?") { _, _ in "0" }
        command("*SRE?") { _, _ in "0" }
        command("*STB?") { _, _ in "0" }
        command("*TRG") { [unowned self] _, _ in
            // Measured: *TRG only acts with TRIG:SOUR BUS (ignored with MANUAL).
            if settings["TRIG:SOUR"] == "BUS", inputOn, seqStart == nil, activeFunction == "LIST" || activeFunction == "PROGRAM" {
                seqStart = Date(); seqStep = 1
            }
            return nil
        }
        command("SYSTem:ERRor?") { [unowned self] _, _ in errors.isEmpty ? "+0, No error" : errors.removeFirst() }

        command("MEASure:VOLTage[:DC]?") { [unowned self] _, _ in f6(operatingPoint().v) }
        command("MEASure:CURRent[:DC]?") { [unowned self] _, _ in f6(operatingPoint().i) }
        command("MEASure:POWer[:DC]?") { [unowned self] _, _ in let p = operatingPoint(); return f6(p.v * p.i) }
        command("MEASure:RESistance[:DC]?") { [unowned self] _, _ in
            let p = operatingPoint(); return f6(p.i > 1e-6 ? p.v / p.i : 0)
        }
        command("MEASure:EXT?") { [unowned self] _, _ in f6(0) }
        command("MEASure:WAVEdata?") { [unowned self] _, _ in
            let p = operatingPoint()
            return Array(repeating: String(format: "%.4f", p.v), count: 200).joined(separator: ",")
        }

        command("[:SOURce]:INPut[:STATe]") { [unowned self] a, _ in
            if let s = a.first?.uppercased() {
                let on = s == "ON" || s == "1"
                if on && !inputOn && activeFunction == "BATTERY" { dischargedmAh = 0; dischargeSeconds = 0 }
                if on && !inputOn {
                    seqStep = 0; seqLoadOff = false
                    // OCPT/OPPT start immediately; List/Program wait for a trigger.
                    seqStart = (activeFunction == "OCP" || activeFunction == "OPP") ? Date() : nil
                    if activeFunction == "OCP" || activeFunction == "OPP" { seqStep = 1 }
                    if activeFunction == "PROGRAM" { programMeasured = [] }
                }
                if !on { seqStart = nil }
                inputOn = on
            }
            return nil
        }
        command("[:SOURce]:INPut[:STATe]?") { [unowned self] _, _ in inputOn ? "1" : "0" }
        command("[:SOURce]:SHORt[:STATe]") { [unowned self] a, _ in
            if let s = a.first?.uppercased() { shortOn = s == "ON" || s == "1" }; return nil
        }
        command("[:SOURce]:SHORt[:STATe]?") { [unowned self] _, _ in shortOn ? "1" : "0" }

        // Static function. Setting it exits Battery/List/Program/OCP/OPP.
        setting("[:SOURce]:FUNCtion", key: ":FUNC", .enumeration(modes, "CURRENT"))
        let funcSet = Array(commands.suffix(2))
        commands.removeLast(2)
        command("[:SOURce]:FUNCtion") { [unowned self] a, q in
            // Real SDL: selecting a function switches the input OFF.
            activeFunction = "BASIC"; dynamicActive = false; inputOn = false
            return funcSet[0].1(a, q)
        }
        commands.append(funcSet[1])
        setting("[:SOURce]:FUNCtion:TRANsient", key: ":FUNC:TRAN", .enumeration(Array(modes.prefix(4)), "CURRENT"))
        let tranSet = Array(commands.suffix(2))
        commands.removeLast(2)
        command("[:SOURce]:FUNCtion:TRANsient") { [unowned self] a, q in
            activeFunction = "BASIC"; dynamicActive = true; dynamicEpoch = Date(); inputOn = false
            // Static mode follows the transient mode (both queries report the same name).
            if let m = a.first { settings[":FUNC"] = modes.first { $0.hasPrefix(String(m.uppercased().prefix(3))) } ?? "CURRENT" }
            return tranSet[0].1(a, q)
        }
        commands.append(tranSet[1])

        for (sub, key, lvl) in [("CURRent", ":CURR", 0.0), ("VOLTage", ":VOLT", 10.0), ("POWer", ":POW", 0.0), ("RESistance", ":RES", 1000.0)] {
            setting("[:SOURce]:\(sub)[:LEVel][:IMMediate]", key: key, .double(lvl))
            setting("[:SOURce]:\(sub):IRANGe", key: "\(key):IRANG", iR)
            setting("[:SOURce]:\(sub):VRANGe", key: "\(key):VRANG", vR)
            setting("[:SOURce]:\(sub):TRANsient:MODE", key: "\(key):TRAN:MODE", .enumeration(tmode, "CONTINUOUS"))
            setting("[:SOURce]:\(sub):TRANsient:IRANGe", key: "\(key):TRAN:IRANG", iR)
            setting("[:SOURce]:\(sub):TRANsient:VRANGe", key: "\(key):TRAN:VRANG", vR)
            for p in ["ALEVel", "BLEVel", "AWIDth", "BWIDth"] {
                setting("[:SOURce]:\(sub):TRANsient:\(p)", key: "\(key):TRAN:\(p.prefix(4))", .double(1))
            }
        }
        setting("[:SOURce]:RESistance:RRANGe", key: ":RES:RRANG", .enumeration(rr, "LOW"))
        setting("[:SOURce]:RESistance:TRANsient:RRANGe", key: ":RES:TRAN:RRANG", .enumeration(rr, "LOW"))
        setting("[:SOURce]:CURRent:SLEW[:BOTH]", key: ":CURR:SLEW:BOTH", .double(0.5))
        setting("[:SOURce]:CURRent:SLEW:POSitive", key: ":CURR:SLEW:POS", .double(0.5))
        setting("[:SOURce]:CURRent:SLEW:NEGative", key: ":CURR:SLEW:NEG", .double(0.5))
        setting("[:SOURce]:CURRent:TRANsient:SLEW:POSitive", key: ":CURR:TRAN:SLEW:POS", .double(0.5))
        setting("[:SOURce]:CURRent:TRANsient:SLEW:NEGative", key: ":CURR:TRAN:SLEW:NEG", .double(0.5))
        setting("[:SOURce]:LED:IRANGe", key: ":LED:IRANG", iR)
        setting("[:SOURce]:LED:VRANGe", key: ":LED:VRANG", vR)
        setting("[:SOURce]:LED:VOLTage", key: ":LED:VOLT", .double(3))
        setting("[:SOURce]:LED:CURRent", key: ":LED:CURR", .double(0.1))
        setting("[:SOURce]:LED:RCOnf", key: ":LED:RCONF", .double(0.2))

        // Battery
        command("[:SOURce]:BATTery:FUNC") { [unowned self] _, _ in activeFunction = "BATTERY"; return nil }
        command("[:SOURce]:BATTery:FUNC?") { [unowned self] _, _ in activeFunction == "BATTERY" ? "1" : "0" }
        setting("[:SOURce]:BATTery:MODE", key: ":BATT:MODE", .enumeration(["CURRENT", "POWER", "RESISTANCE"], "CURRENT"))
        setting("[:SOURce]:BATTery:IRANGe", key: ":BATT:IRANG", iR)
        setting("[:SOURce]:BATTery:VRANGe", key: ":BATT:VRANG", vR)
        setting("[:SOURce]:BATTery:RRANGe", key: ":BATT:RRANG", .enumeration(rr, "LOW"))
        setting("[:SOURce]:BATTery:LEVel", key: ":BATT:LEV", .double(1))
        setting("[:SOURce]:BATTery:VOLTage", key: ":BATT:VOLT", .double(0))
        setting("[:SOURce]:BATTery:CAPability", key: ":BATT:CAP", .double(0))
        setting("[:SOURce]:BATTery:TIMer", key: ":BATT:TIM", .double(0))
        setting("[:SOURce]:BATTery:VOLTage:STATe", key: ":BATT:VOLT:STAT", .bool(false))
        setting("[:SOURce]:BATTery:CAPability:STATe", key: ":BATT:CAP:STAT", .bool(false))
        setting("[:SOURce]:BATTery:TIMer:STATe", key: ":BATT:TIM:STAT", .bool(false))
        command("[:SOURce]:BATTery:DISCHArg:CAPability?") { [unowned self] _, _ in String(Int(dischargedmAh)) }
        command("[:SOURce]:BATTery:DISCHArg:TIMer?") { [unowned self] _, _ in String(Int(dischargeSeconds)) }
        for p in ["TIME1", "TIME2", "CURR1", "CURR2"] {
            setting("[:SOURce]:BATTery:DCR:\(p)", key: ":BATT:DCR:\(p)", .double(1))
        }
        command("[:SOURce]:BATTery:DCR:RESult?") { [unowned self] _, _ in f6(_sourceResistance) }

        // List
        setting("[:SOURce]:LIST:MODE", key: ":LIST:MODE", .enumeration(Array(modes.prefix(4)), "CURRENT"))
        setting("[:SOURce]:LIST:IRANGe", key: ":LIST:IRANG", iR)
        setting("[:SOURce]:LIST:VRANGe", key: ":LIST:VRANG", vR)
        setting("[:SOURce]:LIST:RRANGe", key: ":LIST:RRANG", .enumeration(rr, "LOW"))
        setting("[:SOURce]:LIST:COUNt", key: ":LIST:COUN", .int(1))
        setting("[:SOURce]:LIST:STEP", key: ":LIST:STEP", .int(1))
        setting("[:SOURce]:LIST:LEVel", key: ":LIST:LEV", .double(2), indexed: true)
        setting("[:SOURce]:LIST:SLEW[:BOTH]", key: ":LIST:SLEW", .double(0.5), indexed: true)
        setting("[:SOURce]:LIST:WIDth", key: ":LIST:WID", .double(1), indexed: true)
        command("[:SOURce]:LIST:STATe:ON") { [unowned self] _, _ in activeFunction = "LIST"; inputOn = false; seqStart = nil; seqStep = 0; return nil }
        command("[:SOURce]:LIST:STATe?") { [unowned self] _, _ in activeFunction == "LIST" ? "1" : "0" }

        // OCP / OPP
        for t in ["OCP", "OPP"] {
            command("[:SOURce]:\(t):FUNC") { [unowned self] _, _ in activeFunction = t; inputOn = false; seqStart = nil; return nil }
            command("[:SOURce]:\(t):FUNC?") { [unowned self] _, _ in activeFunction == t ? "1" : "0" }
            setting("[:SOURce]:\(t):IRANGe", key: ":\(t):IRANG", iR)
            setting("[:SOURce]:\(t):VRANGe", key: ":\(t):VRANG", vR)
            for (p, k) in [("STARt", "STAR"), ("STEP", "STEP"), ("STEP:DELay", "STEP:DEL"), ("END", "END"), ("MIN", "MIN"), ("MAX", "MAX"), ("VOLTage", "VOLT")] {
                setting("[:SOURce]:\(t):\(p)", key: ":\(t):\(k)", .double(1))
            }
        }

        // Program
        setting("[:SOURce]:PROGram:STEP", key: ":PROG:STEP", .int(1))
        setting("[:SOURce]:PROGram:MODE", key: ":PROG:MODE", .enumeration(modes, "CURRENT"), indexed: true)
        setting("[:SOURce]:PROGram:IRANGe", key: ":PROG:IRANG", .range(30, threshold: 5, low: 5, high: 30), indexed: true)
        setting("[:SOURce]:PROGram:VRANGe", key: ":PROG:VRANG", .range(150, threshold: 36, low: 36, high: 150), indexed: true)
        setting("[:SOURce]:PROGram:RRANGe", key: ":PROG:RRANG", .enumeration(rr, "LOW"), indexed: true)
        setting("[:SOURce]:PROGram:SHORt", key: ":PROG:SHOR", .bool(false), indexed: true)
        setting("[:SOURce]:PROGram:PAUSE", key: ":PROG:PAUSE", .bool(false), indexed: true)
        setting("[:SOURce]:PROGram:TIME:ON", key: ":PROG:TIME:ON", .double(1), indexed: true)
        setting("[:SOURce]:PROGram:TIME:OFF", key: ":PROG:TIME:OFF", .double(1), indexed: true)
        setting("[:SOURce]:PROGram:TIME:DELay", key: ":PROG:TIME:DEL", .double(1), indexed: true)
        setting("[:SOURce]:PROGram:MIN", key: ":PROG:MIN", .double(1), indexed: true)
        setting("[:SOURce]:PROGram:MAX", key: ":PROG:MAX", .double(10), indexed: true)
        setting("[:SOURce]:PROGram:LEVel", key: ":PROG:LEV", .double(1), indexed: true)
        setting("[:SOURce]:PROGram:LED:CURRent", key: ":PROG:LED:CURR", .double(1), indexed: true)
        setting("[:SOURce]:PROGram:LED:RCOnf", key: ":PROG:LED:RCONF", .double(0.2), indexed: true)
        command("[:SOURce]:PROGram:STATe:ON") { [unowned self] _, _ in activeFunction = "PROGRAM"; inputOn = false; seqStart = nil; seqStep = 0; return nil }
        command("[:SOURce]:PROGram:STATe?") { [unowned self] _, _ in activeFunction == "PROGRAM" ? "1" : "0" }
        command("[:SOURce]:PROGram:TEST?") { [unowned self] a, _ in
            guard let n = a.first.flatMap({ Int($0) }) else { return nil }
            return f6(programResults[n] ?? 0)
        }
        command("[:SOURce]:TEST:STEP?") { [unowned self] _, _ in advanceSequence(); return String(seqStep) }
        command("[:SOURce]:TEST:STOP?") { _, _ in "0" }      // measured: always 0

        // Wave
        command("[:SOURce]:WAVE:TIME?") { _, _ in "8s" }
        setting("[:SOURce]:WAVE:MODE", key: ":WAVE:MODE", .enumeration(Array(modes.prefix(4)), "VOLTAGE"))
        setting("[:SOURce]:WAVE:PAUSE", key: ":WAVE:PAUSE", .bool(false))
        setting("[:SOURce]:WAVE:DISPlay", key: ":WAVE:DISP", .bool(false))

        // Utility
        setting("[:SOURce]:VOLTage[:LEVel]:ON", key: ":VOLT:LEV:ON", .double(0))
        setting("[:SOURce]:VOLTage:LATCh[:STATe]", key: ":VOLT:LATC", .bool(false))
        setting("[:SOURce]:EXT:INPUT[:STATe]", key: ":EXT:INPUT", .bool(false))
        for (sub, key) in [("CURRent", ":CURR"), ("POWer", ":POW")] {
            setting("[:SOURce]:\(sub):PROTection:STATe", key: "\(key):PROT:STAT", .bool(false))
            setting("[:SOURce]:\(sub):PROTection:LEVel", key: "\(key):PROT:LEV", .double(30))
            setting("[:SOURce]:\(sub):PROTection:DELay", key: "\(key):PROT:DEL", .double(0))
        }
        setting("SYSTem:SENSe[:STATe]", key: "SYST:SENS", .bool(false))
        setting("SYSTEM:IMONITOR:STATE", key: "SYST:IMON", .bool(false))
        setting("SYSTEM:VMONITOR:STATE", key: "SYST:VMON", .bool(false))
        setting("STOP:ON:FAIL[:STATe]", key: "STOP:ON:FAIL", .bool(false))
        setting("TRIGger:SOURce", key: "TRIG:SOUR", .enumeration(["MANUAL", "EXTERNAL", "BUS"], "MANUAL"))
        setting("SENSe:AVERage:COUNt", key: "SENS:AVER:COUN", .int(9))
        setting("EXT:MODE", key: "EXT:MODE", .enumeration(["INT", "EXTI", "EXTV"], "INT"))
        setting("EXT:IRANGe", key: "EXT:IRANG", iR)
        setting("EXT:VRANGe", key: "EXT:VRANG", vR)
        setting("TIME:TEST[:STATe]", key: "TIME:TEST", .bool(false))
        setting("TIME:TEST:VOLTage:LOW", key: "TIME:TEST:VOLT:LOW", .double(1))
        setting("TIME:TEST:VOLTage:HIGH", key: "TIME:TEST:VOLT:HIGH", .double(10))
        command("TIME:TEST:RISE?") { _, _ in "0.000" }
        command("TIME:TEST:FALL?") { _, _ in "0.000" }

        // LAN
        command("LAN:LINK?") { _, _ in "1" }
        command("DHCP?") { _, _ in "1" }
        command("LAN:IPADdress?") { _, _ in "127.0.0.1" }
        command("LAN:SMASk?") { _, _ in "255.0.0.0" }
        command("LAN:GATeway?") { _, _ in "127.0.0.1" }
        command("LAN:MAC?") { _, _ in "00.00.00.00.00.00" }
    }
}

private final class LockedOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !done { done = true; body() }
    }
}

extension Duration {
    var seconds: Double {
        let (s, a) = components
        return Double(s) + Double(a) / 1e18
    }
}
