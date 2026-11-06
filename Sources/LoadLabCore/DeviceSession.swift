import Foundation
import Observation
import SCPIKit
import SDLKit

/// The app's single live session with one SDL1000X.
///
/// Owns the only TCP connection the instrument allows, polls measurements, mirrors settings,
/// and applies edits as clamp → write (confirmed) → read back. Reconnects automatically.
@MainActor @Observable
public final class DeviceSession {
    public enum Link: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int, reason: String)
        case failed(String)

        public var isUsable: Bool { self == .connected }
        public var label: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .reconnecting(let n, _): "Reconnecting (attempt \(n))…"
            case .failed(let why): why
            }
        }
    }

    public let host: String
    public let port: UInt16
    public private(set) var link: Link = .disconnected
    public private(set) var identity: InstrumentIdentity?
    public private(set) var state = DeviceState()
    public private(set) var latest: Reading?
    public private(set) var history = MeasurementHistory()
    /// Most recent user-facing problem (cleared on the next successful edit).
    public var lastError: String?
    public private(set) var log: [SCPILogEntry] = []
    public var logEnabled = true

    /// Poll period for V/I/P/R (status is refreshed about once a second regardless).
    /// While recording, the run's sample rate sets this.
    public var pollInterval: Duration = .milliseconds(250)
    /// Idle poll period, restored when a recording ends.
    public var idlePollInterval: Duration = .milliseconds(250)

    /// The active (or last finished) run. Only one at a time.
    public private(set) var recorder: RunRecorder?
    /// Drives an app-scripted profile run (nil for instrument Battery runs).
    public private(set) var profileRunner: ProfileRunner?
    /// A List / Program / OCPT / OPPT run (running or the last finished one).
    public internal(set) var sequence: SequenceRun?
    /// Bumped around app-initiated input changes for sequences, so a status reading taken
    /// meanwhile is ignored (same race as profiles; see hardware-notes).
    var sequenceEpoch = 0
    /// Grace period past an OCPT/OPPT ramp's longest possible duration before LoadLab stops it.
    public static let sequenceOverrun: Double = 3
    /// Results are being collected; the run shows as running until they're in.
    var sequenceFinishing = false
    /// Keeps the Mac from idle-sleeping while a run is active.
    private var sleepActivity: NSObjectProtocol?
    public var runStore = RunStore()

    public let sdl: SDL1000X
    private var pollTask: Task<Void, Never>?
    private var lastStatus = ContinuousClock.now
    private static let logCapacity = 3000
    /// Below this current, resistance readings are meaningless.
    public static let resistanceCurrentFloor = 0.001

    public init(host: String, port: UInt16 = 5025) {
        self.host = host
        self.port = port
        self.sdl = SDL1000X(host: host, port: port)
    }

    // MARK: - Lifecycle

    public func connect() async {
        guard link == .disconnected || isFailed else { return }
        link = .connecting
        await sdl.connection.setLogHandler { [weak self] entry in
            Task { @MainActor in self?.appendLog(entry) }
        }
        do {
            try await openAndSync()
            link = .connected
            startPolling()
        } catch {
            await sdl.connection.disconnect()
            link = .failed(Self.describe(error, host: host))
        }
    }

    public func disconnect() async {
        if let r = recorder, r.isActive { r.addEvent("disconnect", "LoadLab disconnected; the instrument continues on its own") }
        pollTask?.cancel()
        pollTask = nil
        await sdl.connection.disconnect()
        link = .disconnected
    }

    private var isFailed: Bool { if case .failed = link { true } else { false } }

    private func openAndSync() async throws {
        try await sdl.connection.connect()
        do {
            identity = try await sdl.identity()
        } catch SCPIError.connectionClosed {
            throw SessionError.busy
        }
        _ = try await sdl.drainErrors()
        try await refreshAll()
    }

    public enum SessionError: Error, Equatable { case busy }

    static func describe(_ error: Error, host: String) -> String {
        if let e = error as? SessionError, e == .busy {
            return "\(host) is in use by another program (the SDL allows one connection at a time)"
        }
        if let e = error as? SCPIError {
            switch e {
            case .localNetworkDenied:
                return "macOS is blocking LoadLab from the local network. Allow it in System Settings → Privacy & Security → Local Network, then try again."
            case .connectFailed(let why): return "Can't reach \(host): \(why)"
            case .connectionClosed: return "\(host) closed the connection"
            default: return e.description
            }
        }
        return error.localizedDescription
    }

    // MARK: - Polling & reconnect

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let started = ContinuousClock.now
                await self.pollOnce()
                let period = self.pollInterval
                let elapsed = ContinuousClock.now - started
                if elapsed < period { try? await Task.sleep(for: period - elapsed) }
            }
        }
    }

    private func pollOnce() async {
        guard link == .connected else { return }
        do {
            // Above 4 Hz read only V and I (2 round trips); P and R are derived.
            var m = pollInterval < .milliseconds(250) ? try await sdl.measureFast() : try await sdl.measureAll()
            // With (almost) no current, the SDL's resistance reading is V / noise. Report 0
            // ("no reading") instead; the UI shows "—".
            if abs(m.current) < Self.resistanceCurrentFloor { m.resistance = 0 }
            latest = m
            history.append(m)
            recorder?.ingest(m)
            if profileRunner?.isActive == true { await checkProfileSafety(m) }
            if sequence?.phase == .running, sequence?.function == .ocpt || sequence?.function == .oppt { sequence?.trace.append(m) }
            if ContinuousClock.now - lastStatus >= .seconds(1) {
                lastStatus = ContinuousClock.now
                try await refreshStatus()
            }
        } catch {
            await handleLinkError(error)
        }
    }

    /// Decides whether an error means the link is gone; if so, reconnects with backoff.
    private func handleLinkError(_ error: Error) async {
        let timeouts = await sdl.connection.consecutiveTimeouts
        let fatal: Bool
        switch error as? SCPIError {
        case .notConnected, .connectionClosed, .connectFailed: fatal = true
        case .timeout: fatal = timeouts >= 3
        default: fatal = false
        }
        guard fatal else {
            lastError = "\(error)"
            return
        }
        await reconnect(reason: "\(error)")
    }

    private var reconnecting = false

    private func reconnect(reason: String) async {
        guard !reconnecting else { return }
        reconnecting = true
        defer { reconnecting = false }
        var attempt = 0
        while !Task.isCancelled {
            attempt += 1
            link = .reconnecting(attempt: attempt, reason: reason)
            await sdl.connection.disconnect()
            do {
                try await openAndSync()
                link = .connected
                lastError = nil
                if recorder?.isActive == true { recorder?.addEvent("reconnect", "Reconnected after: \(reason)") }
                // A profile never continues across a dropped connection: the app was out of
                // the loop, so switch the input off and end the run.
                if profileRunner?.isActive == true || profileRunner?.linkLost == true {
                    try? await sdl.setInput(false)
                    state.inputOn = (try? await sdl.inputOn()) ?? state.inputOn
                    await endRun(status: .stopped, reason: .connectionLost)
                }
                return
            } catch {
                let delay = min(10.0, pow(2.0, Double(min(attempt, 4))) * 0.5)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    // MARK: - Reading state

    /// Full settings read (~70 queries, ~1 s). Called on connect and reconnect.
    public func refreshAll() async throws {
        var s = state
        s.inputOn = try await sdl.inputOn()
        s.shortOn = try await sdl.shortOn()
        s.function = try await readFunction()
        s.mode = try await sdl.function()
        for m in [LoadMode.cc, .cv, .cp, .cr] {
            var c = s[mode: m]
            c.level = try await sdl.level(m)
            c.currentRange = try await sdl.currentRange(m)
            c.voltageRange = try await sdl.voltageRange(m)
            c.transientMode = try await sdl.transientMode(m)
            c.transientCurrentRange = try await sdl.transientCurrentRange(m)
            c.transientVoltageRange = try await sdl.transientVoltageRange(m)
            c.aLevel = try await sdl.transient(m, .aLevel)
            c.bLevel = try await sdl.transient(m, .bLevel)
            c.aWidth = try await sdl.transient(m, .aWidth)
            c.bWidth = try await sdl.transient(m, .bWidth)
            s[mode: m] = c
        }
        var led = s[mode: .led]
        led.currentRange = try await sdl.currentRange(.led)
        led.voltageRange = try await sdl.voltageRange(.led)
        s[mode: .led] = led
        s.resistanceRange = try await sdl.resistanceRange()
        s.slewRise = try await sdl.slewRise()
        s.slewFall = try await sdl.slewFall()
        s.transientSlewRise = try await sdl.transientSlewRise()
        s.transientSlewFall = try await sdl.transientSlewFall()
        s.ledVoltage = try await sdl.ledVoltage()
        s.ledCurrent = try await sdl.ledCurrent()
        s.ledRco = try await sdl.ledRco()
        s.sense = try await sdl.sense()
        s.vOn = try await sdl.vOn()
        s.vOnLatch = try await sdl.vOnLatch()
        s.currentProtection = try await readProtection(.current)
        s.powerProtection = try await readProtection(.power)
        s.averageExponent = try await sdl.averageExponent()
        s.triggerSource = try await sdl.triggerSource()
        s.stopOnFail = try await sdl.stopOnFail()
        s.extInputSwitch = try await sdl.extInputSwitch()
        s.currentMonitor = try await sdl.currentMonitor()
        s.voltageMonitor = try await sdl.voltageMonitor()
        s.externalMode = try await sdl.externalMode()
        s.extCurrentRange = try await sdl.externalCurrentRange()
        s.extVoltageRange = try await sdl.externalVoltageRange()
        if s.function != .basic { s.dynamic = false }
        s.battery = try await readBattery()
        s.batteryCapacity_mAh = try await sdl.batteryDischargedCapacity()
        s.batteryTime_s = try await sdl.batteryDischargeTime()
        state = s
    }

    func readBattery() async throws -> BatteryConfig {
        var c = BatteryConfig()
        c.mode = try await sdl.batteryMode()
        c.currentRange = try await sdl.batteryCurrentRange()
        c.voltageRange = try await sdl.batteryVoltageRange()
        c.resistanceRange = try await sdl.batteryResistanceRange() ?? .low
        c.level = try await sdl.batteryLevel()
        c.stopVoltageEnabled = try await sdl.batteryStopVoltageEnabled()
        c.stopVoltage = try await sdl.batteryStopVoltage()
        c.stopCapacityEnabled = try await sdl.batteryStopCapacityEnabled()
        c.stopCapacity = try await sdl.batteryStopCapacity()
        c.stopTimeEnabled = try await sdl.batteryStopTimeEnabled()
        c.stopTime = try await sdl.batteryStopTime()
        return c
    }

    private func readProtection(_ p: SDL1000X.Protection) async throws -> ProtectionConfig {
        var c = ProtectionConfig()
        c.enabled = try await sdl.protectionEnabled(p)
        c.level = try await sdl.protectionLevel(p)
        c.delay = try await sdl.protectionDelay(p)
        return c
    }

    private func readFunction() async throws -> ActiveFunction {
        if try await sdl.inBattery() { return .battery }
        if try await sdl.inList() { return .list }
        if try await sdl.inProgram() { return .program }
        if try await sdl.inProtectionTest(.ocp) { return .ocpt }
        if try await sdl.inProtectionTest(.opp) { return .oppt }
        if try await sdl.externalMode() != .internalControl { return .ext }
        return .basic
    }

    /// Cheap periodic status: input, short, active function (front-panel changes show up here).
    private func refreshStatus() async throws {
        let generation = profileRunner?.inputGeneration
        let seqEpoch = sequenceEpoch
        let input = try await sdl.inputOn()
        let short = try await sdl.shortOn()
        let fn = try await readFunction()
        let wasOn = state.inputOn
        state.inputOn = input
        state.shortOn = short
        if fn != state.function {
            state.function = fn
            if fn != .basic { state.dynamic = false }
        }
        if fn == .battery {
            state.batteryCapacity_mAh = try await sdl.batteryDischargedCapacity()
            state.batteryTime_s = try await sdl.batteryDischargeTime()
            recorder?.updateDeviceCounters(capacity: state.batteryCapacity_mAh, time: state.batteryTime_s)
        }
        // List / Program / OCPT / OPPT: follow the step; the instrument switches the input off at the end.
        if sequence?.phase == .running {
            if sequence?.function == .list || sequence?.function == .program {
                sequence?.step = (try? await sdl.testStep()) ?? sequence?.step ?? 0
            }
            if !input, seqEpoch == sequenceEpoch { await finishSequence(.finished) }
            // OCPT/OPPT that never ends: seen on hardware when the source oscillated in its current
            // limit instead of collapsing, so the instrument neither tripped nor finished the ramp.
            else if let r = sequence, r.phase == .running, r.function == .ocpt || r.function == .oppt {
                let c = r.function == .oppt ? state.oppt : state.ocpt
                if Date().timeIntervalSince(r.started) > c.maxSeconds + Self.sequenceOverrun {
                    sequence?.note = "Stopped by LoadLab: the ramp ran \(Int(Self.sequenceOverrun)) s past its longest possible time without the instrument ending it. The source may be current-limiting without its voltage falling below the trip voltage."
                    await stopSequence()
                }
            }
        }
        // A profile expected the input on, but it went off (front panel, protection…).
        if let r = recorder, r.info.kind == "profile" {
            // Only trust the reading if the runner didn't touch the input meanwhile.
            if r.isActive, !input, profileRunner?.expectInputOn == true, profileRunner?.inputGeneration == generation {
                await endRun(status: .stopped, reason: .inputSwitchedOff)
            }
            return
        }
        // The instrument ended the test (stop condition, front panel, protection…).
        if let r = recorder, r.isActive, wasOn, !input {
            let reason = RunRecorder.inferEndReason(config: r.info.battery, lastVoltage: r.lastLoadedVoltage,
                                                    deviceCapacity: state.batteryCapacity_mAh,
                                                    deviceTime: state.batteryTime_s,
                                                    restingVoltage: latest?.voltage)
            await endRun(status: .completed, reason: reason)
        }
    }

    // MARK: - Edits

    /// Runs an edit: write(s) then read back into `state`. Errors land in `lastError`.
    @discardableResult
    public func perform(_ label: String, _ body: (SDL1000X) async throws -> Void) async -> Bool {
        guard link == .connected else { lastError = "Not connected"; return false }
        do {
            try await body(sdl)
            lastError = nil
            return true
        } catch {
            lastError = "\(label): \(error)"
            await handleLinkError(error)
            return false
        }
    }

    public func setInput(_ on: Bool) async {
        await perform(on ? "Input on" : "Input off") { sdl in
            try await sdl.setInput(on)
            self.state.inputOn = try await sdl.inputOn()
        }
        if !on {
            await endRun(status: .stopped, reason: .userStopped)
            if sequence?.phase == .running { await finishSequence(.stopped) }
        }
    }

    /// Input OFF, bypassing the `.connected` guard so it works mid-reconnect if possible.
    public func emergencyOff() async {
        profileRunner?.halt()          // no more commands from a profile
        do {
            try await sdl.setInput(false)
            state.inputOn = try await sdl.inputOn()
        } catch {
            lastError = "EMERGENCY OFF FAILED: \(error) — switch the input off at the instrument"
        }
        await endRun(status: .stopped, reason: .userStopped)
        if sequence?.phase == .running { await finishSequence(.stopped) }
    }

    public func setShort(_ on: Bool) async {
        await perform("Short") { sdl in
            try await sdl.setShort(on)
            self.state.shortOn = try await sdl.shortOn()
        }
    }

    public func trigger() async { await perform("Trigger") { try await $0.trigger() } }

    /// Selects the Basic mode (static or dynamic per `state.dynamic`). The instrument turns
    /// the input OFF when the mode changes; the read-back reflects that.
    public func setMode(_ m: LoadMode) async {
        let dyn = state.dynamic && m != .led
        await perform("Mode") { sdl in
            if dyn { try await sdl.setTransientFunction(m) } else { try await sdl.setFunction(m) }
            self.state.mode = try await sdl.function()
            self.state.dynamic = dyn
            self.state.function = .basic
            self.state.inputOn = try await sdl.inputOn()
        }
    }

    /// Enters/leaves dynamic operation for the current mode (input turns OFF).
    public func setDynamic(_ on: Bool) async {
        let m = state.mode
        guard m != .led || !on else { lastError = "LED mode has no dynamic operation"; return }
        await perform("Dynamic") { sdl in
            if on { try await sdl.setTransientFunction(m) } else { try await sdl.setFunction(m) }
            self.state.dynamic = on
            self.state.function = .basic
            self.state.inputOn = try await sdl.inputOn()
        }
    }

    /// Leaves Battery/List/Program/OCPT/OPPT/Ext and returns to Basic static operation.
    public func switchToBasic() async {
        let m = state.mode
        await perform("Switch to Basic") { sdl in
            if try await sdl.externalMode() != .internalControl { try await sdl.setExternalMode(.internalControl) }
            try await sdl.setFunction(m)
            self.state.function = .basic
            self.state.dynamic = false
            self.state.inputOn = try await sdl.inputOn()
        }
    }

    public func setLevel(_ m: LoadMode, _ v: Double) async {
        let c = state[mode: m]
        let r = SDLLimits.level(m, currentRange: c.currentRange, voltageRange: c.voltageRange)
        let value = v.clamped(to: r)
        await perform("Level") { sdl in
            try await sdl.setLevel(m, value)
            self.state[mode: m].level = try await sdl.level(m)
        }
    }

    public func setCurrentRange(_ m: LoadMode, _ r: CurrentRange) async {
        let dyn = state.dynamic
        await perform("Current range") { sdl in
            if dyn {
                try await sdl.setTransientCurrentRange(m, r)
                self.state[mode: m].transientCurrentRange = try await sdl.transientCurrentRange(m)
            } else {
                try await sdl.setCurrentRange(m, r)
                self.state[mode: m].currentRange = try await sdl.currentRange(m)
            }
            // A range change can clamp levels and slew; re-read them.
            self.state[mode: m].level = try await sdl.level(m)
            self.state.slewRise = try await sdl.slewRise()
            self.state.slewFall = try await sdl.slewFall()
        }
    }

    public func setVoltageRange(_ m: LoadMode, _ r: VoltageRange) async {
        let dyn = state.dynamic
        await perform("Voltage range") { sdl in
            if dyn {
                try await sdl.setTransientVoltageRange(m, r)
                self.state[mode: m].transientVoltageRange = try await sdl.transientVoltageRange(m)
            } else {
                try await sdl.setVoltageRange(m, r)
                self.state[mode: m].voltageRange = try await sdl.voltageRange(m)
            }
            self.state[mode: m].level = try await sdl.level(m)
        }
    }

    public func setResistanceRange(_ r: ResistanceRange) async {
        await perform("Resistance range") { sdl in
            try await sdl.setResistanceRange(r)
            self.state.resistanceRange = try await sdl.resistanceRange()
        }
    }

    public enum SlewEdge: Sendable { case rise, fall }

    public func setSlew(_ edge: SlewEdge, _ v: Double) async {
        let dyn = state.dynamic
        let range = state.activeCurrentRange
        let value = v.clamped(to: SDLLimits.slew(range))
        await perform("Slew") { sdl in
            switch (edge, dyn) {
            case (.rise, false): try await sdl.setSlewRise(value); self.state.slewRise = try await sdl.slewRise()
            case (.fall, false): try await sdl.setSlewFall(value); self.state.slewFall = try await sdl.slewFall()
            case (.rise, true): try await sdl.setTransientSlewRise(value); self.state.transientSlewRise = try await sdl.transientSlewRise()
            case (.fall, true): try await sdl.setTransientSlewFall(value); self.state.transientSlewFall = try await sdl.transientSlewFall()
            }
        }
    }

    public func setTransientMode(_ m: LoadMode, _ t: TransientMode) async {
        let reenter = state.dynamic && state.mode == m
        await perform("Dynamic mode") { sdl in
            try await sdl.setTransientMode(m, t)
            self.state[mode: m].transientMode = try await sdl.transientMode(m)
            // Measured: a new transient mode only takes effect after re-entering dynamic.
            if reenter {
                try await sdl.setTransientFunction(m)
                self.state.inputOn = try await sdl.inputOn()
            }
        }
    }

    public func setTransient(_ m: LoadMode, _ p: SDL1000X.TransientParam, _ v: Double) async {
        let c = state[mode: m]
        let value: Double
        switch p {
        case .aLevel, .bLevel:
            value = v.clamped(to: SDLLimits.level(m, currentRange: c.transientCurrentRange, voltageRange: c.transientVoltageRange))
        case .aWidth, .bWidth:
            value = v.clamped(to: SDLLimits.transientWidth(m))
        }
        await perform("Dynamic setting") { sdl in
            try await sdl.setTransient(m, p, value)
            let got = try await sdl.transient(m, p)
            switch p {
            case .aLevel: self.state[mode: m].aLevel = got
            case .bLevel: self.state[mode: m].bLevel = got
            case .aWidth: self.state[mode: m].aWidth = got
            case .bWidth: self.state[mode: m].bWidth = got
            }
        }
    }

    public enum LEDParam: Sendable { case voltage, current, rco }

    public func setLED(_ p: LEDParam, _ v: Double) async {
        await perform("LED setting") { sdl in
            switch p {
            case .voltage: try await sdl.setLedVoltage(max(0, v)); self.state.ledVoltage = try await sdl.ledVoltage()
            case .current: try await sdl.setLedCurrent(max(0, v)); self.state.ledCurrent = try await sdl.ledCurrent()
            case .rco: try await sdl.setLedRco(max(0, v)); self.state.ledRco = try await sdl.ledRco()
            }
        }
    }

    // MARK: System settings

    public func setSense(_ on: Bool) async {
        await perform("Sense") { sdl in try await sdl.setSense(on); self.state.sense = try await sdl.sense() }
    }
    public func setVOn(_ v: Double) async {
        await perform("Von") { sdl in
            try await sdl.setVOn(v.clamped(to: SDLLimits.vOn)); self.state.vOn = try await sdl.vOn()
        }
    }
    public func setVOnLatch(_ on: Bool) async {
        await perform("Von latch") { sdl in try await sdl.setVOnLatch(on); self.state.vOnLatch = try await sdl.vOnLatch() }
    }
    public func setProtection(_ p: SDL1000X.Protection, _ c: ProtectionConfig) async {
        await perform("Protection") { sdl in
            try await sdl.setProtectionLevel(p, max(0, c.level))
            try await sdl.setProtectionDelay(p, max(0, c.delay))
            try await sdl.setProtectionEnabled(p, c.enabled)
            let read = try await self.readProtection(p)
            if p == .current { self.state.currentProtection = read } else { self.state.powerProtection = read }
        }
    }
    public func setAverageExponent(_ n: Int) async {
        await perform("Averaging") { sdl in
            try await sdl.setAverageExponent(n.clamped(to: SDLLimits.averageExponent))
            self.state.averageExponent = try await sdl.averageExponent()
        }
    }
    public func setTriggerSource(_ t: TriggerSource) async {
        await perform("Trigger source") { sdl in try await sdl.setTriggerSource(t); self.state.triggerSource = try await sdl.triggerSource() }
    }
    public func setStopOnFail(_ on: Bool) async {
        await perform("Stop on fail") { sdl in try await sdl.setStopOnFail(on); self.state.stopOnFail = try await sdl.stopOnFail() }
    }
    public func setMonitors(current: Bool, voltage: Bool) async {
        await perform("Monitor outputs") { sdl in
            try await sdl.setCurrentMonitor(current); try await sdl.setVoltageMonitor(voltage)
            self.state.currentMonitor = try await sdl.currentMonitor()
            self.state.voltageMonitor = try await sdl.voltageMonitor()
        }
    }

    // MARK: Battery

    /// Switches the instrument to the Battery function (input turns off).
    public func enterBattery() async {
        await perform("Enter Battery") { sdl in
            try await sdl.enterBattery()
            self.state.function = .battery
            self.state.dynamic = false
            self.state.inputOn = try await sdl.inputOn()
            self.state.battery = try await self.readBattery()
        }
    }

    /// Writes battery settings that differ from the instrument's, then reads them all back.
    @discardableResult
    public func applyBattery(_ wanted: BatteryConfig) async -> Bool {
        var c = wanted
        c.level = c.level.clamped(to: c.levelRange)
        c.stopVoltage = max(0, c.stopVoltage)
        c.stopCapacity = max(0, c.stopCapacity)
        c.stopTime = max(0, c.stopTime)
        let have = state.battery
        return await perform("Battery settings") { sdl in
            if c.mode != have.mode { try await sdl.setBatteryMode(c.mode) }
            if c.currentRange != have.currentRange { try await sdl.setBatteryCurrentRange(c.currentRange) }
            if c.voltageRange != have.voltageRange { try await sdl.setBatteryVoltageRange(c.voltageRange) }
            if c.mode == .cr, c.resistanceRange != have.resistanceRange { try await sdl.setBatteryResistanceRange(c.resistanceRange) }
            if c.level != have.level { try await sdl.setBatteryLevel(c.level) }
            if c.stopVoltage != have.stopVoltage { try await sdl.setBatteryStopVoltage(c.stopVoltage) }
            if c.stopCapacity != have.stopCapacity { try await sdl.setBatteryStopCapacity(c.stopCapacity) }
            if c.stopTime != have.stopTime { try await sdl.setBatteryStopTime(c.stopTime) }
            if c.stopVoltageEnabled != have.stopVoltageEnabled { try await sdl.setBatteryStopVoltageEnabled(c.stopVoltageEnabled) }
            if c.stopCapacityEnabled != have.stopCapacityEnabled { try await sdl.setBatteryStopCapacityEnabled(c.stopCapacityEnabled) }
            if c.stopTimeEnabled != have.stopTimeEnabled { try await sdl.setBatteryStopTimeEnabled(c.stopTimeEnabled) }
            self.state.battery = try await self.readBattery()
        }
    }

    public enum RunStartError: Error, Equatable, CustomStringConvertible {
        case notConnected, alreadyRunning, noStopCondition, settingsRejected(String), cutoffNotVerified, inputDidNotStart
        public var description: String {
            switch self {
            case .notConnected: "Not connected"
            case .alreadyRunning: "A run is already in progress"
            case .noStopCondition: "Enable at least one stop condition (voltage, capacity or time)"
            case .settingsRejected(let why): "The instrument did not accept the settings: \(why)"
            case .cutoffNotVerified: "Could not verify the hardware cut-off (Von / latch off); not starting"
            case .inputDidNotStart: "The input did not switch on (is the battery voltage above Von?)"
            }
        }
    }

    /// Starts a battery discharge run: applies and verifies settings, arms the hardware
    /// cut-off, opens the recording, and switches the input on.
    public func startBatteryRun(config: BatteryConfig, cell: CellInfo, options: RecordingOptions) async throws {
        guard link == .connected else { throw RunStartError.notConnected }
        guard recorder?.isActive != true else { throw RunStartError.alreadyRunning }
        guard config.hasStopCondition else { throw RunStartError.noStopCondition }

        if state.inputOn { await setInput(false) }
        if state.function != .battery { await enterBattery() }
        guard state.function == .battery else { throw RunStartError.settingsRejected(lastError ?? "could not enter Battery") }
        guard await applyBattery(config) else { throw RunStartError.settingsRejected(lastError ?? "write failed") }
        let applied = state.battery
        guard applied.mode == config.mode, applied.stopVoltageEnabled == config.stopVoltageEnabled,
              applied.stopCapacityEnabled == config.stopCapacityEnabled, applied.stopTimeEnabled == config.stopTimeEnabled,
              abs(applied.stopVoltage - config.stopVoltage) < 0.001 else {
            throw RunStartError.settingsRejected("read-back differs")
        }

        var info = RunInfo(title: cell.name.isEmpty ? "Battery test" : cell.name, cell: cell, battery: applied,
                           options: options, startedAt: Date())
        info.deviceModel = identity?.model
        info.deviceSerial = identity?.serial
        info.deviceFirmware = identity?.firmware
        info.deviceHost = host

        // Hardware cut-off: Von just below V_Stop with latch OFF stops the load even if the
        // Mac sleeps or the network drops (verified on hardware: < 1 mA below Von).
        if options.hardwareCutoff && applied.stopVoltageEnabled {
            info.savedVOn = state.vOn
            info.savedVOnLatch = state.vOnLatch
            let von = max(0, applied.stopVoltage - options.hardwareCutoffMargin)
            await setVOn(von)
            await setVOnLatch(false)
            guard abs(state.vOn - von) < 0.001, state.vOnLatch == false else {
                await restoreVOn(info)
                throw RunStartError.cutoffNotVerified
            }
        }

        let r = try RunRecorder(info: info, store: runStore)
        recorder = r
        // A resting (open-circuit) reading just before the load starts: gives the analysis an
        // OCV and a "load applied" resistance step.
        if let rest = try? await sdl.measureAll() { r.ingest(rest) }
        pollInterval = .milliseconds(Int(1000 / options.sampleRateHz.clamped(to: 0.5...10)))
        await setInput(true)
        guard state.inputOn else {
            r.finish(status: .failed, reason: .error)
            await restoreVOn(r.info)
            pollInterval = idlePollInterval
            throw RunStartError.inputDidNotStart
        }
        r.addEvent("input", String(format: "Input on: %@ %.3f %@", applied.mode.label, applied.level, applied.mode.unit))
        beginSleepActivity()
    }

    /// Stops the run from the app (input OFF first).
    public func stopRun() async {
        await emergencyOff()
        await endRun(status: .stopped, reason: .userStopped)
    }

    private func endRun(status: RunStatus, reason: EndReason) async {
        guard let r = recorder, r.isActive, !ending else { return }
        ending = true
        defer { ending = false }
        if r.info.kind == "profile" {
            // Stop the engine before anything else, then make sure the load is off.
            profileRunner?.halt()
            if (try? await sdl.setInput(false)) == nil {
                lastError = "Could not switch the input off — check the instrument"
            }
            state.inputOn = (try? await sdl.inputOn()) ?? state.inputOn
        }
        // One reading with the load off, for the "load removed" resistance step / rest voltage.
        if var after = try? await sdl.measureAll() {
            if abs(after.current) < Self.resistanceCurrentFloor { after.resistance = 0 }
            r.ingest(after)
        }
        if state.function == .battery {
            if let c = try? await sdl.batteryDischargedCapacity(), let t = try? await sdl.batteryDischargeTime() {
                r.updateDeviceCounters(capacity: c, time: t)
            }
        }
        // Clean up *before* marking the run finished, so "finished" means the user's
        // Von/latch are back.
        await restoreVOn(r.info)
        if let b = r.info.savedBasic { await restoreBasic(b) }
        pollInterval = idlePollInterval
        endSleepActivity()
        r.finish(status: status, reason: reason)
    }
    private var ending = false

    private func restoreVOn(_ info: RunInfo) async {
        if let v = info.savedVOn { await setVOn(v) }
        if let l = info.savedVOnLatch { await setVOnLatch(l) }
    }

    /// After connecting: re-attach to a run this instrument was doing when LoadLab quit.
    /// If the instrument is still discharging, recording resumes; otherwise the run is closed
    /// with the instrument's (persisted) counters as the final figures.
    public func resumeInterruptedRuns() async {
        guard link == .connected, recorder == nil else { return }
        for (folder, _) in runStore.runningRuns(serial: identity?.serial) {
            guard let r = try? RunRecorder(resuming: folder, store: runStore) else { continue }
            if r.info.kind == "profile" {
                // Profiles can't continue without LoadLab in the loop: make sure the load is off.
                if state.inputOn {
                    try? await sdl.setInput(false)
                    state.inputOn = (try? await sdl.inputOn()) ?? state.inputOn
                    r.addEvent("safety", "Input switched off on reconnect (the profile can't continue)")
                }
                r.finish(status: .interrupted, reason: .endedWhileDisconnected)
                await restoreVOn(r.info)
                if let b = r.info.savedBasic { await restoreBasic(b) }
                if recorder == nil { recorder = r }
                continue
            }
            if state.function == .battery && state.inputOn && recorder == nil {
                r.updateDeviceCounters(capacity: state.batteryCapacity_mAh, time: state.batteryTime_s)
                recorder = r
                pollInterval = .milliseconds(Int(1000 / r.info.options.sampleRateHz.clamped(to: 0.5...10)))
                beginSleepActivity()
            } else {
                r.updateDeviceCounters(capacity: state.batteryCapacity_mAh, time: state.batteryTime_s)
                r.finish(status: .interrupted, reason: .endedWhileDisconnected)
                await restoreVOn(r.info)
                if recorder == nil { recorder = r }
            }
        }
    }

    /// Clears a finished run from the screen (files stay on disk).
    public func dismissRun() {
        if recorder?.isActive != true { recorder = nil; profileRunner = nil }
    }

    private func beginSleepActivity() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "LoadLab is recording a discharge run")
    }

    private func endSleepActivity() {
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a) }
        sleepActivity = nil
    }

    /// True while the Mac is being kept awake for a run.
    public var preventingSleep: Bool { sleepActivity != nil }

    // MARK: Console

    /// Raw command from the debug console. Queries return their reply.
    public func raw(_ command: String) async -> String {
        guard link == .connected else { return "Not connected" }
        let header = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        do {
            if header.hasSuffix("?") { return try await sdl.query(command) }
            try await sdl.write(command)
            let errs = try await sdl.drainErrors()
            return errs.isEmpty ? "OK" : errs.map { "\($0.code), \($0.message)" }.joined(separator: "\n")
        } catch {
            return "Error: \(error)"
        }
    }

    public func clearHistory() { history.clear() }

    private func appendLog(_ e: SCPILogEntry) {
        guard logEnabled else { return }
        log.append(e)
        if log.count > Self.logCapacity { log.removeFirst(log.count - Self.logCapacity) }
    }
    public func clearLog() { log.removeAll() }
}

// MARK: - Profiles (app-scripted discharges)

extension DeviceSession {
    public enum ProfileStartError: Error, Equatable, CustomStringConvertible {
        case invalid([String]), belowCutoff(Double), couldNotPrepare(String)
        public var description: String {
            switch self {
            case .invalid(let problems): problems.joined(separator: " ")
            case .belowCutoff(let v): String(format: "The cell reads %.3f V, at or below the cut-off. Not starting.", v)
            case .couldNotPrepare(let why): "Could not prepare the instrument: \(why)"
            }
        }
    }

    /// Starts an app-scripted profile: switches to Basic (static), sets ranges, arms the Von
    /// failsafe, records, and hands control to a `ProfileRunner`.
    public func startProfileRun(_ profile: Profile, cell: CellInfo) async throws {
        guard link == .connected else { throw RunStartError.notConnected }
        guard recorder?.isActive != true else { throw RunStartError.alreadyRunning }
        let problems = profile.validate()
        guard problems.isEmpty else { throw ProfileStartError.invalid(problems) }

        if state.inputOn { await setInput(false) }
        let saved = SavedBasic(
            mode: state.mode, dynamic: state.dynamic,
            modes: [LoadMode.cc, .cp, .cr].map {
                SavedBasic.Mode(mode: $0, level: state[mode: $0].level,
                                currentRange: state[mode: $0].currentRange, voltageRange: state[mode: $0].voltageRange)
            },
            resistanceRange: state.resistanceRange)

        // Basic, static, the profile's ranges, and the first loaded step's mode.
        let firstMode = profile.allSteps.first { [.hold, .pulse, .dcr].contains($0.kind) }?.mode ?? .cc
        let ok = await perform("Prepare profile") { sdl in
            if try await sdl.externalMode() != .internalControl { try await sdl.setExternalMode(.internalControl) }
            for m in profile.modesUsed.union([firstMode]) {
                try await sdl.setFunction(m.loadMode)
                try await sdl.setCurrentRange(m.loadMode, profile.currentRange)
                try await sdl.setVoltageRange(m.loadMode, profile.voltageRange)
                guard try await sdl.currentRange(m.loadMode) == profile.currentRange,
                      try await sdl.voltageRange(m.loadMode) == profile.voltageRange else {
                    throw ProfileStartError.couldNotPrepare("range read-back differs for \(m.label)")
                }
            }
            if profile.modesUsed.contains(.cr) { try await sdl.setResistanceRange(profile.resistanceRange) }
            try await sdl.setFunction(firstMode.loadMode)
            self.state.function = .basic
            self.state.dynamic = false
            self.state.mode = firstMode.loadMode
            self.state.inputOn = try await sdl.inputOn()
        }
        guard ok, !state.inputOn else {
            await restoreBasic(saved)
            throw ProfileStartError.couldNotPrepare(lastError ?? "input did not stay off")
        }

        // The cell must be above the cut-off before anything starts.
        guard let rest = try? await sdl.measureAll() else {
            await restoreBasic(saved)
            throw ProfileStartError.couldNotPrepare("no reading")
        }
        guard rest.voltage > profile.limits.cutoffVoltage else {
            await restoreBasic(saved)
            throw ProfileStartError.belowCutoff(rest.voltage)
        }

        var battery = BatteryConfig()
        battery.mode = .cc
        battery.level = profile.maxCCLevel
        battery.currentRange = profile.currentRange
        battery.voltageRange = profile.voltageRange
        battery.stopVoltageEnabled = true
        battery.stopVoltage = profile.limits.cutoffVoltage
        var options = RecordingOptions()
        options.sampleRateHz = profile.sampleRateHz
        options.hardwareCutoff = true
        options.hardwareCutoffMargin = profile.limits.hardwareMargin
        var info = RunInfo(title: cell.name.isEmpty ? profile.name : "\(cell.name) · \(profile.name)", cell: cell,
                           battery: battery, options: options, startedAt: Date())
        info.kind = "profile"
        info.profile = profile
        info.savedBasic = saved
        info.deviceModel = identity?.model
        info.deviceSerial = identity?.serial
        info.deviceFirmware = identity?.firmware
        info.deviceHost = host

        // Failsafe: Von just below the cut-off, latch off (always on for profiles).
        info.savedVOn = state.vOn
        info.savedVOnLatch = state.vOnLatch
        let von = max(0, profile.limits.cutoffVoltage - profile.limits.hardwareMargin)
        await setVOn(von)
        await setVOnLatch(false)
        guard abs(state.vOn - von) < 0.001, state.vOnLatch == false else {
            await restoreVOn(info)
            await restoreBasic(saved)
            throw RunStartError.cutoffNotVerified
        }

        let r = try RunRecorder(info: info, store: runStore)
        recorder = r
        r.ingest(rest)
        r.addEvent("safety", String(format: "Cut-off %.3f V · max %.3f A · Von %.3f V (latch off)",
                                    profile.limits.cutoffVoltage, profile.limits.maxCurrent, von))
        pollInterval = .milliseconds(Int(1000 / profile.sampleRateHz.clamped(to: 0.5...10)))
        beginSleepActivity()
        let runner = ProfileRunner(profile: profile, session: self, recorder: r, initialMode: firstMode)
        profileRunner = runner
        runner.start()
    }

    /// Per-sample watchdog for profile runs. Runs in the polling path, independent of the
    /// runner's own timing.
    func checkProfileSafety(_ m: Reading) async {
        guard let p = profileRunner, p.isActive, let r = recorder, r.isActive else { return }
        let l = p.profile.limits
        if m.current > l.maxCurrent + l.currentTolerance {
            r.addEvent("safety", String(format: "Current %.4f A above the %.3f A limit", m.current, l.maxCurrent))
            await endRun(status: .stopped, reason: .currentLimit)
        } else if m.current > RunAnalysis.currentFloor && m.voltage <= l.cutoffVoltage {
            await endRun(status: .completed, reason: .voltageCutoff)
        } else if let q = l.maxCapacity_mAh, r.integrator.capacity_mAh >= q {
            await endRun(status: .completed, reason: .capacityLimit)
        } else if let t = l.maxDuration_s, m.date.timeIntervalSince(r.info.startedAt) >= t {
            await endRun(status: .completed, reason: .timeLimit)
        }
    }

    /// The runner reached the end of its steps (or failed cleanly).
    func profileFinished(status: RunStatus, reason: EndReason) async {
        await endRun(status: status, reason: reason)
    }

    /// The runner switched the input; keeps the mirror current between status polls.
    func noteProfileInput(_ on: Bool) { state.inputOn = on }

    /// Puts back the Basic mode, levels and ranges a profile changed (input must be off).
    func restoreBasic(_ b: SavedBasic) async {
        await perform("Restore Basic settings") { sdl in
            for m in b.modes {
                if try await sdl.currentRange(m.mode) != m.currentRange { try await sdl.setCurrentRange(m.mode, m.currentRange) }
                if try await sdl.voltageRange(m.mode) != m.voltageRange { try await sdl.setVoltageRange(m.mode, m.voltageRange) }
                if abs(try await sdl.level(m.mode) - m.level) > 1e-9 { try await sdl.setLevel(m.mode, m.level) }
            }
            if try await sdl.resistanceRange() != b.resistanceRange { try await sdl.setResistanceRange(b.resistanceRange) }
            if b.dynamic { try await sdl.setTransientFunction(b.mode) } else { try await sdl.setFunction(b.mode) }
            self.state.dynamic = b.dynamic
            try await self.refreshAll()
        }
    }
}

// MARK: - List / Program / OCPT / OPPT / Ext

extension DeviceSession {
    // Entering a function (the instrument switches the input off).

    public func enterFunction(_ f: ActiveFunction) async {
        guard f != state.function else { return }
        if state.inputOn { await setInput(false) }
        await perform("Switch to \(f.label)") { sdl in
            switch f {
            case .basic: try await sdl.setFunction(self.state.mode)
            case .battery: try await sdl.enterBattery()
            case .list: try await sdl.enterList()
            case .program: try await sdl.enterProgram()
            case .ocpt: try await sdl.enterProtectionTest(.ocp)
            case .oppt: try await sdl.enterProtectionTest(.opp)
            case .ext:
                if try await sdl.externalMode() == .internalControl { try await sdl.setExternalMode(.externalVoltage) }
            }
            if f != .ext, try await sdl.externalMode() != .internalControl { try await sdl.setExternalMode(.internalControl) }
            self.state.externalMode = try await sdl.externalMode()
            self.state.function = try await self.readFunctionPublic()
            self.state.dynamic = false
            self.state.inputOn = try await sdl.inputOn()
        }
    }

    func readFunctionPublic() async throws -> ActiveFunction {
        if try await sdl.inBattery() { return .battery }
        if try await sdl.inList() { return .list }
        if try await sdl.inProgram() { return .program }
        if try await sdl.inProtectionTest(.ocp) { return .ocpt }
        if try await sdl.inProtectionTest(.opp) { return .oppt }
        if try await sdl.externalMode() != .internalControl { return .ext }
        return .basic
    }

    // List

    public func loadList() async {
        await perform("Read List") { sdl in
            var c = ListConfig()
            c.mode = try await sdl.listMode()
            c.currentRange = try await sdl.listCurrentRange()
            c.voltageRange = try await sdl.listVoltageRange()
            c.resistanceRange = try await sdl.listResistanceRange() ?? .low
            c.count = try await sdl.listCount()
            let n = try await sdl.listStepCount().clamped(to: SDLLimits.listSteps)
            c.steps = []
            for k in 1...n { c.steps.append(try await sdl.listStep(k)) }
            self.state.list = c
        }
    }

    /// Writes what differs (entering List first: step edits are ignored otherwise), then reads back.
    @discardableResult
    public func applyList(_ wanted: ListConfig) async -> Bool {
        let have = state.list
        let ok = await perform("Write List") { sdl in
            if !(try await sdl.inList()) {
                if self.state.inputOn { try await sdl.setInput(false) }
                try await sdl.enterList()
                self.state.function = .list
            }
            if wanted.mode != have.mode { try await sdl.setListMode(wanted.mode) }
            if wanted.currentRange != have.currentRange { try await sdl.setListCurrentRange(wanted.currentRange) }
            if wanted.voltageRange != have.voltageRange { try await sdl.setListVoltageRange(wanted.voltageRange) }
            if wanted.mode == .cr, wanted.resistanceRange != have.resistanceRange { try await sdl.setListResistanceRange(wanted.resistanceRange) }
            if wanted.count != have.count { try await sdl.setListCount(wanted.count) }
            if wanted.steps.count != have.steps.count { try await sdl.setListStepCount(wanted.steps.count) }
            for (i, st) in wanted.steps.enumerated() {
                let n = i + 1
                let old = i < have.steps.count ? have.steps[i] : nil
                if old.map({ !approx($0.level, st.level) }) ?? true { try await sdl.write(":LIST:LEV \(n),\(StepCSV.fmt(st.level))") }
                if old.map({ !approx($0.width, st.width) }) ?? true { try await sdl.write(":LIST:WID \(n),\(StepCSV.fmt(st.width))") }
                if old.map({ !approx($0.slew, st.slew) }) ?? true { try await sdl.write(":LIST:SLEW \(n),\(StepCSV.fmt(st.slew))") }
            }
        }
        await loadList()
        return ok && lastError == nil
    }

    // Program

    public func loadProgram() async {
        await perform("Read Program") { sdl in
            var c = ProgramConfig()
            let n = try await sdl.programStepCount().clamped(to: SDLLimits.programSteps)
            c.steps = []
            for k in 1...n { c.steps.append(try await sdl.programStep(k, full: true)) }
            c.stopOnFail = try await sdl.stopOnFail()
            self.state.program = c
            self.state.stopOnFail = c.stopOnFail
        }
    }

    @discardableResult
    public func applyProgram(_ wanted: ProgramConfig) async -> Bool {
        let have = state.program
        let ok = await perform("Write Program") { sdl in
            if !(try await sdl.inProgram()) {
                if self.state.inputOn { try await sdl.setInput(false) }
                try await sdl.enterProgram()
                self.state.function = .program
            }
            if wanted.steps.count != have.steps.count { try await sdl.setProgramStepCount(wanted.steps.count) }
            for (i, st) in wanted.steps.enumerated() {
                let old = i < have.steps.count ? have.steps[i] : nil
                try await sdl.setProgramStep(i + 1, st, changedFrom: old)
            }
            if wanted.stopOnFail != have.stopOnFail { try await sdl.setStopOnFail(wanted.stopOnFail) }
        }
        await loadProgram()
        return ok && lastError == nil
    }

    // OCPT / OPPT

    private func testKind(_ f: ActiveFunction) -> SDL1000X.ProtectionTest { f == .oppt ? .opp : .ocp }

    public func loadProtectionTest(_ f: ActiveFunction) async {
        let t = testKind(f)
        await perform("Read \(t.label)") { sdl in
            var c = ProtectionTestConfig()
            c.currentRange = try await sdl.protectionTestCurrentRange(t)
            c.voltageRange = try await sdl.protectionTestVoltageRange(t)
            c.start = try await sdl.protectionTest(t, .start)
            c.step = try await sdl.protectionTest(t, .step)
            c.stepDelay = try await sdl.protectionTest(t, .stepDelay)
            c.end = try await sdl.protectionTest(t, .end)
            c.min = try await sdl.protectionTest(t, .min)
            c.max = try await sdl.protectionTest(t, .max)
            c.voltage = try await sdl.protectionTest(t, .voltage)
            if t == .opp { self.state.oppt = c } else { self.state.ocpt = c }
        }
    }

    @discardableResult
    public func applyProtectionTest(_ f: ActiveFunction, _ wanted: ProtectionTestConfig) async -> Bool {
        let t = testKind(f)
        let have = t == .opp ? state.oppt : state.ocpt
        let ok = await perform("Write \(t.label)") { sdl in
            if !(try await sdl.inProtectionTest(t)) {
                if self.state.inputOn { try await sdl.setInput(false) }
                try await sdl.enterProtectionTest(t)
                self.state.function = f
            }
            if wanted.currentRange != have.currentRange { try await sdl.setProtectionTestCurrentRange(t, wanted.currentRange) }
            if wanted.voltageRange != have.voltageRange { try await sdl.setProtectionTestVoltageRange(t, wanted.voltageRange) }
            let pre = ":\(t.rawValue):"
            // start ≤ end and min ≤ max are kept by clamping on the instrument: order matters.
            try await sdl.writePair(lo: (pre + "STAR", wanted.start, have.start), hi: (pre + "END", wanted.end, have.end))
            try await sdl.writePair(lo: (pre + "MIN", wanted.min, have.min), hi: (pre + "MAX", wanted.max, have.max))
            let rest: [(SDL1000X.ProtectionParam, Double, Double)] = [
                (.step, wanted.step, have.step), (.stepDelay, wanted.stepDelay, have.stepDelay), (.voltage, wanted.voltage, have.voltage)]
            for (p, w, h) in rest where !approx(w, h) { try await sdl.setProtectionTest(t, p, w) }
        }
        await loadProtectionTest(f)
        return ok && lastError == nil
    }

    // Ext

    public func setExternal(mode: ExternalMode? = nil, currentRange: CurrentRange? = nil, voltageRange: VoltageRange? = nil) async {
        await perform("External control") { sdl in
            if let m = mode {
                if self.state.inputOn { try await sdl.setInput(false); self.state.inputOn = false }
                try await sdl.setExternalMode(m)
            }
            if let r = currentRange { try await sdl.setExternalCurrentRange(r) }
            if let r = voltageRange { try await sdl.setExternalVoltageRange(r) }
            self.state.externalMode = try await sdl.externalMode()
            self.state.extCurrentRange = try await sdl.externalCurrentRange()
            self.state.extVoltageRange = try await sdl.externalVoltageRange()
            self.state.function = try await self.readFunctionPublic()
        }
    }

    public func setExtInputSwitch(_ on: Bool) async {
        await perform("External on/off") { sdl in
            try await sdl.setExtInputSwitch(on)
            self.state.extInputSwitch = try await sdl.extInputSwitch()
        }
    }

    /// Reads the rear-panel control voltage (call periodically while the Ext screen shows).
    public func refreshExtControlVoltage() async {
        guard link == .connected else { return }
        state.extControlVoltage = try? await sdl.measureExternal()
    }

    // Running

    public enum SequenceStartError: Error, Equatable, CustomStringConvertible {
        case notConnected, busy, wrongFunction(ActiveFunction), invalid([String]), didNotStart
        public var description: String {
            switch self {
            case .notConnected: "Not connected"
            case .busy: "Another run is in progress"
            case .wrongFunction(let f): "The instrument isn't in \(f.label)"
            case .invalid(let p): p.joined(separator: " ")
            case .didNotStart: "The instrument did not start (input stayed off)"
            }
        }
    }

    /// Starts the instrument's own List / Program / OCPT / OPPT run. List and Program are
    /// armed by input ON and started by a bus trigger (measured: `*TRG` is ignored with the
    /// MANUAL source, so the source is switched to BUS for the run and restored after).
    /// OCPT/OPPT start at input ON and are sampled fast to catch the trip point.
    public func startSequence(_ f: ActiveFunction) async throws {
        guard link == .connected else { throw SequenceStartError.notConnected }
        guard recorder?.isActive != true, sequence?.phase != .running else { throw SequenceStartError.busy }
        guard state.function == f || (f == .ocpt && state.function == .ocpt) || (f == .oppt && state.function == .oppt) else {
            throw SequenceStartError.wrongFunction(f)
        }
        if state.inputOn { await setInput(false) }
        var run = SequenceRun(function: f)
        sequenceEpoch += 1
        defer { sequenceEpoch += 1 }
        do {
            switch f {
            case .list, .program:
                let src = try await sdl.triggerSource()
                if src != .bus {
                    run.savedTriggerSource = src
                    try await sdl.setTriggerSource(.bus)
                    state.triggerSource = .bus
                }
                try await sdl.setInput(true)
                state.inputOn = true
                sequence = run
                try await sdl.trigger()
            case .ocpt, .oppt:
                pollInterval = .milliseconds(50)
                sequence = run
                try await sdl.setInput(true)
                state.inputOn = true
            default:
                throw SequenceStartError.wrongFunction(f)
            }
        } catch {
            sequence = run
            await finishSequence(.stopped)
            lastError = "Start: \(error)"
            throw error
        }
    }

    /// Ends the sequence: puts the trigger source back and collects results.
    func finishSequence(_ phase: SequenceRun.Phase) async {
        guard var run = sequence, run.phase == .running, !sequenceFinishing else { return }
        sequenceFinishing = true
        defer { sequenceFinishing = false }
        run.ended = Date()
        pollInterval = recorder?.isActive == true ? pollInterval : idlePollInterval
        if (try? await sdl.inputOn()) == true { try? await sdl.setInput(false) }
        state.inputOn = (try? await sdl.inputOn()) ?? false
        switch run.function {
        case .program:
            var results: [ProgramResult] = []
            for (i, st) in state.program.steps.enumerated() {
                guard let raw = try? await sdl.programResult(i + 1), let v = SCPIParse.double(raw) else { continue }
                results.append(ProgramResult(step: i + 1, value: v, min: st.min, max: st.max, unit: st.measuredQuantity.unit))
            }
            run.programResults = results
        case .ocpt, .oppt:
            let c = run.function == .oppt ? state.oppt : state.ocpt
            run.protectionResult = ProtectionResult.analyse(trace: run.trace, config: c, isPower: run.function == .oppt)
        case .list:
            run.step = (try? await sdl.testStep()) ?? run.step
        default: break
        }
        if let src = run.savedTriggerSource {
            try? await sdl.setTriggerSource(src)
            state.triggerSource = (try? await sdl.triggerSource()) ?? state.triggerSource
        }
        // Readings taken while results were collected belong to the run too.
        if let live = sequence { run.trace = live.trace }
        run.phase = phase           // finished only once results and the trigger source are settled
        sequence = run
    }

    public func stopSequence() async {
        await setInput(false)
        if sequence?.phase == .running { await finishSequence(.stopped) }
    }

    public func dismissSequence() { if sequence?.phase != .running { sequence = nil } }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
