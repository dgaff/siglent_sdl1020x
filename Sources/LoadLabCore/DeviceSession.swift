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

    /// Poll period for V/I/P/R. Every 4th tick also refreshes input/short/function status.
    public var pollInterval: Duration = .milliseconds(250)

    public let sdl: SDL1000X
    private var pollTask: Task<Void, Never>?
    private var tick = 0
    private static let logCapacity = 3000

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
            let m = try await sdl.measureAll()
            latest = m
            history.append(m)
            tick += 1
            if tick % 4 == 0 { try await refreshStatus() }
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
        state = s
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
        state.inputOn = input
        state.shortOn = short
        if fn != state.function {
            state.function = fn
            if fn != .basic { state.dynamic = false }
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
    }

    /// Input OFF, bypassing the `.connected` guard so it works mid-reconnect if possible.
    public func emergencyOff() async {
        do {
            try await sdl.setInput(false)
            state.inputOn = try await sdl.inputOn()
        } catch {
            lastError = "EMERGENCY OFF FAILED: \(error) — switch the input off at the instrument"
        }
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
