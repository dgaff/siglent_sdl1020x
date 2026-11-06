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
        if !on { await endRun(status: .stopped, reason: .userStopped) }
    }

    /// Input OFF, bypassing the `.connected` guard so it works mid-reconnect if possible.
    public func emergencyOff() async {
        do {
            try await sdl.setInput(false)
            state.inputOn = try await sdl.inputOn()
        } catch {
            lastError = "EMERGENCY OFF FAILED: \(error) — switch the input off at the instrument"
        }
        await endRun(status: .stopped, reason: .userStopped)
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
        pollInterval = .milliseconds(Int(1000 / options.sampleRateHz.clamped(to: 0.5...10)))
        await setInput(true)
        guard state.inputOn else {
            r.finish(status: .failed, reason: .error)
            await restoreVOn(r.info)
            pollInterval = idlePollInterval
            throw RunStartError.inputDidNotStart
        }
        r.addEvent("input", String(format: "Input on: %@ %.3f %@", applied.mode.label, applied.level, applied.mode.unit))
    }

    /// Stops the run from the app (input OFF first).
    public func stopRun() async {
        await emergencyOff()
        await endRun(status: .stopped, reason: .userStopped)
    }

    private func endRun(status: RunStatus, reason: EndReason) async {
        guard let r = recorder, r.isActive else { return }
        if state.function == .battery {
            if let c = try? await sdl.batteryDischargedCapacity(), let t = try? await sdl.batteryDischargeTime() {
                r.updateDeviceCounters(capacity: c, time: t)
            }
        }
        r.finish(status: status, reason: reason)
        await restoreVOn(r.info)
        pollInterval = idlePollInterval
    }

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
            if state.function == .battery && state.inputOn && recorder == nil {
                r.updateDeviceCounters(capacity: state.batteryCapacity_mAh, time: state.batteryTime_s)
                recorder = r
                pollInterval = .milliseconds(Int(1000 / r.info.options.sampleRateHz.clamped(to: 0.5...10)))
            } else {
                r.updateDeviceCounters(capacity: state.batteryCapacity_mAh, time: state.batteryTime_s)
                r.finish(status: .interrupted, reason: .endedWhileDisconnected)
                await restoreVOn(r.info)
                if recorder == nil { recorder = r }
            }
        }
    }

    /// Clears a finished run from the screen (files stay on disk).
    public func dismissRun() { if recorder?.isActive != true { recorder = nil } }

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

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
