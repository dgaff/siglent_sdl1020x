import Foundation
import Observation
import SCPIKit
import SDLKit

/// Executes a `Profile` against the instrument in Basic static mode.
///
/// Safety is layered and does not depend on this class behaving:
/// 1. `DeviceSession` checks every sample (cut-off, current, capacity, time) and stops the
///    run itself, cancelling this runner.
/// 2. Von (latch off) is armed just below the cut-off before the input first turns on, so the
///    instrument stops sinking on its own if the Mac sleeps, crashes or loses the network.
/// 3. If the connection drops, the session switches the input off on reconnect and ends
///    the run; a profile is never resumed.
@MainActor @Observable
public final class ProfileRunner {
    public let profile: Profile
    /// Executed-step counter (1-based) and description of the current step.
    public private(set) var stepNumber = 0
    public private(set) var stepID: UUID?
    public private(set) var stepText = ""
    public private(set) var stepStartedAt: Date?
    /// Current repeat iteration for each active loop.
    public private(set) var loopIterations: [UUID: Int] = [:]
    public private(set) var dcrResults: [DCRResult] = []
    /// What the input should be, so the session can tell an unexpected switch-off.
    public private(set) var expectInputOn = false
    /// Bumped before and after every input change the runner makes. A status reading only
    /// counts if this didn't change while it was being taken (otherwise it may be stale).
    public private(set) var inputGeneration = 0
    public private(set) var isActive = true
    /// Set when a command failed because the link went down; the session cleans up on reconnect.
    public private(set) var linkLost = false

    private unowned let session: DeviceSession
    private let recorder: RunRecorder
    private var task: Task<Void, Never>?
    /// Basic mode the instrument is in (FUNC switches the input off, so it's tracked).
    private var currentMode: StepMode?
    private var inputOn = false

    init(profile: Profile, session: DeviceSession, recorder: RunRecorder, initialMode: StepMode?) {
        self.profile = profile
        self.session = session
        self.recorder = recorder
        self.currentMode = initialMode
    }

    func start() {
        task = Task { [weak self] in await self?.run() }
    }

    /// Called by the session when the run ends for any reason. After this, no command is sent.
    func halt() {
        isActive = false
        expectInputOn = false
        task?.cancel()
    }

    private struct Halted: Error {}

    private func run() async {
        do {
            try await execute(profile.steps)
            guard isActive else { return }
            await session.profileFinished(status: .completed, reason: .profileFinished)
        } catch is Halted {
            return
        } catch is CancellationError {
            return
        } catch {
            guard isActive else { return }
            if session.link == .connected, (try? await session.sdl.setInput(false)) != nil {
                recorder.addEvent("error", "Profile stopped: \(error)")
                await session.profileFinished(status: .failed, reason: .error)
            } else {
                // The link is down: the reconnect handler switches the input off and ends the run.
                linkLost = true
                expectInputOn = false
                recorder.addEvent("error", "Connection problem during a profile: \(error)")
            }
        }
    }

    // MARK: - Steps

    private func execute(_ steps: [ProfileStep]) async throws {
        for s in steps { try await exec(s) }
    }

    private func begin(_ s: ProfileStep) {
        stepNumber += 1
        stepID = s.id
        stepText = "\(s.kind.label): \(s.summary)"
        stepStartedAt = Date()
        recorder.addEvent("step", "Step \(stepNumber) · \(stepText)")
    }

    private func exec(_ s: ProfileStep) async throws {
        try check()
        switch s.kind {
        case .mark:
            recorder.addEvent("mark", s.label.isEmpty ? "Mark" : s.label)

        case .hold:
            begin(s)
            try await load(s.mode, s.level)
            let q0 = recorder.integrator.capacity_mAh
            let since = Date()
            let ended = try await wait(seconds: s.duration) { [recorder] sample in
                if let q = s.untilCapacity, recorder.integrator.capacity_mAh - q0 >= q { return true }
                if let v = s.untilVoltage, sample.date > since, sample.current > RunAnalysis.currentFloor, sample.voltage <= v { return true }
                return false
            }
            let delivered = recorder.integrator.capacity_mAh - q0
            recorder.addEvent("step-end", String(format: "Step %d delivered %.2f mAh (%@)", stepNumber, delivered, ended ? "end condition" : "time"))

        case .rest:
            begin(s)
            try await unload()
            _ = try await wait(seconds: s.duration) { _ in false }

        case .pulse:
            begin(s)
            for _ in 0..<(s.count ?? 0) {
                try await load(s.mode, s.level)
                _ = try await wait(seconds: s.duration) { _ in false }
                try await load(s.mode, s.level2)
                _ = try await wait(seconds: s.duration2) { _ in false }
            }

        case .dcr:
            begin(s)
            try await load(.cc, s.level)
            _ = try await wait(seconds: s.duration) { _ in false }
            let a = try await measure()
            try await load(.cc, s.level2)
            _ = try await wait(seconds: s.duration2) { _ in false }
            let b = try await measure()
            let r = DCRResult(t: Date().timeIntervalSince(recorder.info.startedAt), capacity_mAh: recorder.integrator.capacity_mAh,
                              i1: a.current, v1: a.voltage, i2: b.current, v2: b.voltage)
            if abs(r.i2 - r.i1) > 0.005 {
                dcrResults.append(r)
                recorder.addDCR(r)
                recorder.addEvent("dcr", String(format: "DC resistance %.1f mΩ at %.1f mAh (%.3f A → %.3f A, %.4f V → %.4f V)",
                                                r.milliohms, r.capacity_mAh, r.i1, r.i2, r.v1, r.v2))
            } else {
                recorder.addEvent("dcr", "DC resistance skipped: the current did not change (is the cell above Von?)")
            }

        case .loop:
            var k = 0
            while s.count.map({ k < $0 }) ?? true {
                k += 1
                guard k <= 10_000 else { break }
                loopIterations[s.id] = k
                recorder.addEvent("loop", "Repeat \(k)\(s.count.map { " of \($0)" } ?? "")")
                try await execute(s.children)
                if let q = s.untilCapacity, recorder.integrator.capacity_mAh >= q { break }
                if let v = s.untilVoltage, let last = recorder.lastLoadedVoltage, last <= v { break }
            }
            loopIterations[s.id] = nil
        }
    }

    // MARK: - Instrument actions (each checks that the run is still ours first)

    private func check() throws {
        if Task.isCancelled || !isActive { throw Halted() }
    }

    /// Sets mode and level, then switches the input on if needed. Changing mode switches the
    /// input off (instrument behaviour), so it is switched back on after the level is set.
    private func load(_ mode: StepMode, _ level: Double) async throws {
        try check()
        let sdl = session.sdl
        if currentMode != mode {
            expectInputOn = false
            inputGeneration += 1
            defer { inputGeneration += 1 }
            try await sdl.setFunction(mode.loadMode)
            currentMode = mode
            inputOn = false
            session.noteProfileInput(false)
            try check()
        }
        try await sdl.setLevel(mode.loadMode, level)
        try check()
        if !inputOn {
            inputGeneration += 1
            defer { inputGeneration += 1 }
            try await sdl.setInput(true)
            inputOn = true
            session.noteProfileInput(true)
            expectInputOn = true
            try check()
        }
    }

    private func unload() async throws {
        try check()
        expectInputOn = false
        inputGeneration += 1
        defer { inputGeneration += 1 }
        if inputOn || session.state.inputOn {
            try await session.sdl.setInput(false)
            inputOn = false
            session.noteProfileInput(false)
        }
        try check()
    }

    private func measure() async throws -> Reading {
        try check()
        let m = try await session.sdl.measureFast()
        try check()
        return m
    }

    /// Waits until `seconds` pass (if given) or `done` returns true for a new sample.
    /// Returns true if `done` ended the wait.
    private func wait(seconds: Double?, _ done: (RunSample) -> Bool) async throws -> Bool {
        let start = ContinuousClock.now
        var lastChecked = recorder.samples.count
        while true {
            try check()
            if session.link != .connected { throw SCPIError.notConnected }
            if let d = seconds, ContinuousClock.now - start >= .milliseconds(Int(d * 1000)) { return false }
            let samples = recorder.samples
            if samples.count > lastChecked {
                for s in samples[lastChecked...] where done(s) { return true }
                lastChecked = samples.count
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
