import Foundation
import Testing
@testable import LoadLabCore
@testable import SDLKit
import SCPIKit

/// T2: live SDL sinking real current from the Keysight E36234A **output 2** (output 1 is not
/// connected and is never touched). All currents stay below 1 A: the supply's current limit is
/// capped at 0.9 A in code and the tests use ≤ 0.8 A.
///
/// Run with:  SDL_HW_HOST=192.168.1.10 PSU_HW_HOST=192.168.1.85 swift test --filter HardwareT2
let psuHost = ProcessInfo.processInfo.environment["PSU_HW_HOST"]

/// Minimal E36234A driver, output 2 only.
struct BenchSupply {
    static let channel = "(@2)"
    static let maxCurrent = 0.9          // user rule: test currents below 1 A
    let conn: SCPIConnection

    init(host: String) { conn = SCPIConnection(host: host) }

    func connect() async throws {
        try await conn.connect()
        let idn = try await conn.query("*IDN?")
        guard idn.contains("E36234A") else { throw SCPIError.invalidResponse(command: "*IDN?", response: idn) }
        // Output 1 is not wired: it must be off and stays untouched.
        guard try await conn.query("OUTP? (@1)") == "0" else {
            throw SCPIError.invalidResponse(command: "OUTP? (@1)", response: "ON — refusing to run")
        }
    }

    func set(volts: Double, amps: Double) async throws {
        precondition(amps < Self.maxCurrent + 1e-9, "test current limit must stay below 1 A")
        precondition(volts <= 30, "test voltage limit")
        try await conn.write("CURR \(amps),\(Self.channel)")
        try await conn.write("VOLT \(volts),\(Self.channel)")
    }
    func output(_ on: Bool) async throws { try await conn.write("OUTP \(on ? "ON" : "OFF"),\(Self.channel)") }
    func outputOn() async throws -> Bool { try await conn.query("OUTP? \(Self.channel)") == "1" }
    func voltage() async throws -> Double { SCPIParse.double(try await conn.query("MEAS:VOLT? \(Self.channel)")) ?? .nan }
    func current() async throws -> Double { SCPIParse.double(try await conn.query("MEAS:CURR? \(Self.channel)")) ?? .nan }
}

@MainActor
@Suite("HardwareT2", .serialized, .enabled(if: hwHost != nil && psuHost != nil, "set SDL_HW_HOST and PSU_HW_HOST"))
struct HardwareT2Tests {

    /// PSU output 2 at `volts` with a 0.8 A limit → run body → input OFF, PSU OFF, restore SDL.
    func withRig(volts: Double = 10, amps: Double = 0.8,
                 _ body: (DeviceSession, BenchSupply) async throws -> Void) async throws {
        let psu = BenchSupply(host: psuHost!)
        try await psu.connect()
        let s = DeviceSession(host: hwHost!)
        s.pollInterval = .milliseconds(100)
        await s.connect()
        var bodyError: Error?
        var snap: SettingsSnapshot?
        do {
            try #require(s.link == .connected, "SDL connect failed: \(s.link)")
            try #require(s.state.inputOn == false, "Refusing to start with the SDL input ON")
            snap = try await SettingsSnapshot.take(from: s.sdl)
            try await psu.set(volts: volts, amps: amps)
            try await psu.output(true)
            try await Task.sleep(for: .milliseconds(600))
            try await body(s, psu)
        } catch { bodyError = error }
        // Teardown always runs, in safety order. If the session can't reach the instrument
        // (e.g. a test broke its link), drop it and switch the input off on a fresh connection.
        if (try? await s.sdl.setInput(false)) == nil {
            await s.disconnect()
            let fresh = SDL1000X(host: hwHost!)
            try? await fresh.connection.connect()
            try? await fresh.setInput(false)
            await fresh.connection.disconnect()
            await s.connect()
        }
        try? await psu.output(false)
        #expect((try? await psu.outputOn()) == false, "PSU output 2 did not switch off!")
        if let snap {
            try await snap.restore(to: s.sdl)
            let d = try await snap.diff(against: s.sdl)
            #expect(d.isEmpty, "SDL settings not restored: \(d.map(\.0.query))")
        }
        await s.disconnect()
        await psu.conn.disconnect()
        if let bodyError { throw bodyError }
    }

    func settle(_ ms: Int = 700) async { try? await Task.sleep(for: .milliseconds(ms)) }
    func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

    @Test func constantCurrent() async throws {
        try await withRig { s, psu in
            await s.setMode(.cc)
            await s.setCurrentRange(.cc, .low)
            await s.setLevel(.cc, 0.5)
            await s.setInput(true)
            #expect(s.state.inputOn)
            await settle()
            let i = try await s.sdl.measureCurrent(), v = try await s.sdl.measureVoltage()
            let pi = try await psu.current(), pv = try await psu.voltage()
            print("T2 CC 0.5 A: SDL \(v) V \(i) A | PSU \(pv) V \(pi) A")
            #expect(near(i, 0.5, 0.005))
            #expect(near(pi, 0.5, 0.01))
            #expect(near(v, pv, 0.15), "lead drop larger than expected")
            // Live polling reached the session too.
            #expect(near(s.latest?.current ?? 0, 0.5, 0.01))
        }
    }

    @Test func constantResistance() async throws {
        try await withRig { s, psu in
            await s.setMode(.cr)
            await s.setLevel(.cr, 20)
            await s.setInput(true)
            await settle()
            let i = try await s.sdl.measureCurrent(), v = try await s.sdl.measureVoltage()
            print("T2 CR 20 Ω: \(v) V \(i) A → \(v / i) Ω")
            #expect(near(v / i, 20, 0.4))
        }
    }

    @Test func constantPower() async throws {
        try await withRig { s, psu in
            await s.setMode(.cp)
            await s.setLevel(.cp, 4)
            await s.setInput(true)
            await settle()
            let i = try await s.sdl.measureCurrent(), v = try await s.sdl.measureVoltage()
            print("T2 CP 4 W: \(v) V \(i) A → \(v * i) W")
            #expect(near(v * i, 4, 0.08))
        }
    }

    @Test func constantVoltagePullsSupplyIntoCurrentLimit() async throws {
        try await withRig(volts: 10, amps: 0.6) { s, psu in
            await s.setMode(.cv)
            await s.setLevel(.cv, 8)
            await s.setInput(true)
            await settle(1000)
            let v = try await s.sdl.measureVoltage(), i = try await s.sdl.measureCurrent()
            print("T2 CV 8 V vs PSU 10 V/0.6 A: \(v) V \(i) A")
            #expect(near(v, 8, 0.1))
            #expect(near(i, 0.6, 0.03))       // the supply limits the current
        }
    }

    @Test func dynamicContinuous() async throws {
        try await withRig { s, _ in
            await s.setMode(.cc)
            await s.setDynamic(true)
            await s.setCurrentRange(.cc, .low)
            await s.setTransient(.cc, .aLevel, 0.2)
            await s.setTransient(.cc, .bLevel, 0.6)
            await s.setTransient(.cc, .aWidth, 0.4)
            await s.setTransient(.cc, .bWidth, 0.4)
            s.clearHistory()
            await s.setInput(true)
            try await Task.sleep(for: .seconds(3))
            let levels = Set(s.history.samples.map { ($0.current * 10).rounded() / 10 })
            print("T2 dynamic levels seen: \(levels.sorted())")
            #expect(levels.contains(0.2) && levels.contains(0.6))
            await s.setDynamic(false)
            #expect(!s.state.inputOn, "leaving dynamic should switch the input off")
        }
    }

    @Test func shortCircuitLimitedBySupply() async throws {
        try await withRig(volts: 5, amps: 0.5) { s, psu in
            await s.setMode(.cc)
            await s.setInput(true)
            await s.setShort(true)
            #expect(s.state.shortOn)
            await settle()
            let i = try await s.sdl.measureCurrent(), v = try await s.sdl.measureVoltage()
            print("T2 short vs PSU 5 V/0.5 A: \(v) V \(i) A")
            #expect(near(i, 0.5, 0.03))
            #expect(v < 0.5)
            await s.setShort(false)
            #expect(!s.state.shortOn)
        }
    }

    @Test func emergencyOffAndModeChangeStopSinking() async throws {
        try await withRig { s, _ in
            await s.setMode(.cc)
            await s.setLevel(.cc, 0.3)
            await s.setInput(true)
            await settle()
            let on = try await s.sdl.measureCurrent()
            #expect(near(on, 0.3, 0.005))
            await s.emergencyOff()
            await settle(300)
            let off = try await s.sdl.measureCurrent()
            #expect(off < 0.002)
            await s.setInput(true)
            await settle()
            await s.setMode(.cr)                      // switches input off
            await settle(300)
            #expect(!s.state.inputOn)
            let afterMode = try await s.sdl.measureCurrent()
            #expect(afterMode < 0.002)
        }
    }

    /// The hardware under-voltage cutoff planned for battery safety (Phase 5):
    /// with Von latch OFF the load must stop sinking below Von and resume above it.
    @Test func vOnCutoffLatchOff() async throws {
        try await withRig(volts: 10) { s, psu in
            await s.setMode(.cc)
            await s.setLevel(.cc, 0.3)
            await s.setVOn(8)
            await s.setVOnLatch(false)
            await s.setInput(true)
            await settle()
            let above = try await s.sdl.measureCurrent()
            try await psu.set(volts: 7, amps: 0.8)
            await settle(1000)
            let below = try await s.sdl.measureCurrent()
            try await psu.set(volts: 9, amps: 0.8)
            await settle(1000)
            let back = try await s.sdl.measureCurrent()
            print("T2 Von 8 V latch OFF: 10 V → \(above) A, 7 V → \(below) A, 9 V → \(back) A")
            #expect(near(above, 0.3, 0.005))
            #expect(below < 0.002, "load kept sinking below Von")
            #expect(near(back, 0.3, 0.005))
        }
    }

    /// Documents latch ON: once started, the load keeps sinking even below Von.
    @Test func vOnLatchOnBehaviour() async throws {
        try await withRig(volts: 10) { s, psu in
            await s.setMode(.cc)
            await s.setLevel(.cc, 0.3)
            await s.setVOn(8)
            await s.setVOnLatch(true)
            await s.setInput(true)
            await settle()
            let above = try await s.sdl.measureCurrent()
            try await psu.set(volts: 7, amps: 0.8)
            await settle(1000)
            let below = try await s.sdl.measureCurrent()
            print("T2 Von 8 V latch ON: 10 V → \(above) A, 7 V → \(below) A")
            #expect(near(above, 0.3, 0.005))
            print("OBSERVATION: latch ON below Von sinks \(below) A")
        }
    }

    /// Phase 3: a full battery run, with the supply emulating a cell discharging through
    /// the cut-off. The instrument must end the test; the app must record it correctly and
    /// restore the user's Von/latch.
    @Test func batteryRunEndsAtCutoff() async throws {
        let store = RunStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("loadlab-hw-\(UUID().uuidString)"))
        try await withRig(volts: 4.0, amps: 0.8) { s, psu in
            s.runStore = store
            let vOnBefore = s.state.vOn, latchBefore = s.state.vOnLatch
            var c = BatteryConfig()
            c.mode = .cc; c.currentRange = .low; c.voltageRange = .low; c.level = 0.5
            c.stopVoltageEnabled = true; c.stopVoltage = 3.5
            var cell = CellInfo(); cell.name = "PSU emulated cell"
            var o = RecordingOptions(); o.sampleRateHz = 5
            try await s.startBatteryRun(config: c, cell: cell, options: o)
            #expect(s.state.inputOn)
            #expect(abs(s.state.vOn - 3.4) < 0.001 && s.state.vOnLatch == false, "backup cut-off not armed")
            let r = try #require(s.recorder)
            try await Task.sleep(for: .seconds(4))
            // "Discharge": step the supply down 4.0 → 3.3 V over ~7 s.
            var v = 4.0
            while v > 3.3, r.isActive {
                v -= 0.05
                try await psu.set(volts: v, amps: 0.8)
                try await Task.sleep(for: .milliseconds(500))
            }
            for _ in 0..<20 where r.isActive { try await Task.sleep(for: .milliseconds(250)) }
            print("T2 battery run: status \(r.info.status) reason \(String(describing: r.info.endReason)) "
                  + "app \(r.info.summary.capacity_mAh) mAh device \(String(describing: r.info.summary.deviceCapacity_mAh)) mAh "
                  + "samples \(r.samples.count) lastLoadedV \(String(describing: r.lastLoadedVoltage))")
            #expect(r.info.status == .completed)
            #expect(r.info.endReason == .voltageCutoff)
            #expect(!s.state.inputOn)
            #expect(s.state.vOn == vOnBefore && s.state.vOnLatch == latchBefore, "Von/latch not restored")
            // 0.5 A for ~10–12 s ≈ 1.4–1.7 mAh; device counts whole mAh.
            let dev = r.info.summary.deviceCapacity_mAh ?? -1
            #expect(abs(r.info.summary.capacity_mAh - dev) < 1.0)
            #expect(r.samples.count > 30)
            let rows = try String(contentsOf: r.folder.appendingPathComponent("samples.csv"), encoding: .utf8)
                .split(separator: "\n").count - 1
            #expect(rows == r.samples.count)
        }
        try? FileManager.default.removeItem(at: store.root)
    }

    // MARK: - Phase 5: profile safety

    /// The failsafe a profile relies on: Von (latch off) stops the load with LoadLab fully
    /// disconnected, and the load resumes if the voltage recovers (documented behaviour).
    @Test func vOnFailsafeWithAppDisconnected() async throws {
        try await withRig(volts: 4.0) { s, psu in
            await s.setMode(.cc)
            await s.setCurrentRange(.cc, .low)
            await s.setLevel(.cc, 0.5)
            await s.setVOn(3.5)
            await s.setVOnLatch(false)
            await s.setInput(true)
            await settle(1000)
            let loaded = try await psu.current()
            // LoadLab goes away (as if the Mac slept or the network dropped).
            await s.disconnect()
            try await psu.set(volts: 3.3, amps: 0.8)
            await settle(1500)
            let below = try await psu.current()
            try await psu.set(volts: 3.8, amps: 0.8)
            await settle(1500)
            let recovered = try await psu.current()
            try await psu.set(volts: 3.3, amps: 0.8)
            await settle(1500)
            let belowAgain = try await psu.current()
            await s.connect()
            try #require(s.link == .connected)
            await s.setInput(false)
            print("T2 failsafe (app disconnected, Von 3.5 latch off): 4.0 V → \(loaded) A, 3.3 V → \(below) A, 3.8 V → \(recovered) A, 3.3 V → \(belowAgain) A (PSU readings)")
            #expect(near(loaded, 0.5, 0.02))
            #expect(below < 0.01, "load kept sinking below Von without the app")
            #expect(near(recovered, 0.5, 0.02))
            #expect(belowAgain < 0.01)
        }
    }

    /// A complete profile on the supply: steps, DCR, pulses, then the supply "discharges"
    /// through the cut-off. Everything must be restored (the snapshot diff checks it).
    @Test func profileRunOnSupply() async throws {
        let store = RunStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("loadlab-hw-\(UUID().uuidString)"))
        try await withRig(volts: 4.0, amps: 0.8) { s, psu in
            s.runStore = store
            var p = Profile(name: "HW profile", steps: [
                .mark("Start"),
                .hold(.cc, 0.3, duration: 3),
                .rest(2),
                .dcr(i1: 0.1, t1: 2, i2: 0.6, t2: 2),
                .pulse(.cc, high: 0.5, highSeconds: 1, low: 0.1, lowSeconds: 1, count: 2),
                .hold(.cc, 0.5),
            ])
            p.limits.cutoffVoltage = 3.5
            p.limits.maxCurrent = 0.8
            p.sampleRateHz = 5
            var cell = CellInfo(); cell.name = "PSU emulated cell"
            try await s.startProfileRun(p, cell: cell)
            let r = try #require(s.recorder)
            let runner = try #require(s.profileRunner)
            #expect(abs(s.state.vOn - 3.4) < 0.001 && s.state.vOnLatch == false, "failsafe not armed")
            // During the first hold, the supply sees ~0.3 A.
            try await Task.sleep(for: .seconds(2))
            let holdCurrent = try await psu.current()
            // Wait for the final hold, then ramp the supply down through the cut-off.
            for _ in 0..<200 where runner.stepNumber < 5 && r.isActive { try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .seconds(2))
            var v = 4.0
            while v > 3.3, r.isActive {
                v -= 0.05
                try await psu.set(volts: v, amps: 0.8)
                try await Task.sleep(for: .milliseconds(400))
            }
            for _ in 0..<20 where r.isActive { try await Task.sleep(for: .milliseconds(250)) }
            await settle(500)
            let after = try await psu.current()
            let dcr = r.info.dcrResults?.first
            print("T2 profile: status \(r.info.status) reason \(String(describing: r.info.endReason)) hold \(holdCurrent) A, "
                  + "after \(after) A, DCR \(dcr.map { "\($0.milliohms) mΩ (\($0.i1)→\($0.i2) A, \($0.v1)→\($0.v2) V)" } ?? "none"), "
                  + "steps \(runner.stepNumber), samples \(r.samples.count), \(r.info.summary.capacity_mAh) mAh")
            if r.info.endReason != .voltageCutoff {
                let t0 = r.info.startedAt
                var lastQuery = ""
                for e in s.log where e.date.timeIntervalSince(t0) > -3 {
                    let interesting = e.kind == .write || e.kind == .error || e.kind == .info || e.text.hasPrefix(":INP") || (e.kind == .reply && lastQuery.hasPrefix(":INP"))
                    if e.kind == .query { lastQuery = e.text }
                    if interesting { print(String(format: "LOG %+.3f", e.date.timeIntervalSince(t0)), e.kind, e.text) }
                }
                for e in r.info.events { print("EVENT", String(format: "%.3f", e.t), e.kind, e.text) }
            }
            #expect(near(holdCurrent, 0.3, 0.02))
            #expect(r.info.status == .completed && r.info.endReason == .voltageCutoff)
            #expect(after < 0.01)
            #expect(!s.state.inputOn)
            let d = try #require(dcr)
            #expect(d.milliohms > 0 && d.milliohms < 300, "DCR \(d.milliohms) mΩ (supply + wiring)")
            let currents = r.samples.map(\.current)
            #expect(currents.contains { near($0, 0.5, 0.02) } && currents.contains { near($0, 0.1, 0.02) })
        }
        try? FileManager.default.removeItem(at: store.root)
    }

    /// Losing the connection mid-profile: on reconnect the input goes off and the run ends.
    @Test func profileLinkDropSwitchesInputOff() async throws {
        let store = RunStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("loadlab-hw-\(UUID().uuidString)"))
        try await withRig(volts: 4.0, amps: 0.8) { s, psu in
            s.runStore = store
            var p = Profile(name: "HW link drop", steps: [.hold(.cc, 0.4, duration: 60)])
            p.limits.cutoffVoltage = 3.5
            p.limits.maxCurrent = 0.8
            p.sampleRateHz = 5
            try await s.startProfileRun(p, cell: CellInfo())
            let r = try #require(s.recorder)
            try await Task.sleep(for: .seconds(2))
            let before = try await psu.current()
            await s.sdl.connection.disconnect()          // the network "drops"
            let t0 = ContinuousClock.now
            for _ in 0..<120 where r.isActive { try await Task.sleep(for: .milliseconds(250)) }
            let took = ContinuousClock.now - t0
            for _ in 0..<80 where s.link != .connected { try await Task.sleep(for: .milliseconds(250)) }
            await settle(500)
            let after = try await psu.current()
            print("T2 link drop: before \(before) A, after \(after) A, ended in \(took), reason \(String(describing: r.info.endReason))")
            if r.isActive {
                print("T2 link drop: link now \(s.link)")
                for e in s.log where e.kind == .info || e.kind == .error || e.text.contains("IDN") || e.text.contains("INP") {
                    print(String(format: "LOG %+.3f", e.date.timeIntervalSince(r.info.startedAt)), e.kind, e.text)
                }
            }
            #expect(near(before, 0.4, 0.02))
            #expect(!r.isActive && r.info.endReason == .connectionLost)
            #expect(after < 0.01)
        }
        try? FileManager.default.removeItem(at: store.root)
    }

    // MARK: - Phase 6: List / Program / OCPT / OPPT / Ext

    func waitFor(_ seconds: Double, _ cond: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < end { if cond() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return cond()
    }

    @Test func listRunsOnSupply() async throws {
        try await withRig(volts: 5, amps: 0.8) { s, psu in
            let srcBefore = s.state.triggerSource
            await s.enterFunction(.list)
            try #require(s.state.function == .list)
            await s.loadList()
            var c = s.state.list
            c.mode = .cc; c.currentRange = .low; c.voltageRange = .low; c.count = 2
            c.steps = [ListStep(level: 0.1, width: 1), ListStep(level: 0.3, width: 1), ListStep(level: 0.5, width: 1)]
            #expect(await s.applyList(c))
            #expect(s.state.list.steps.count == 3 && abs(s.state.list.steps[2].level - 0.5) < 1e-6)
            s.clearHistory()
            try await s.startSequence(.list)
            var psuMax = 0.0
            for _ in 0..<40 where s.sequence?.phase == .running {
                psuMax = max(psuMax, (try? await psu.current()) ?? 0)
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(await waitFor(5) { s.sequence?.phase == .finished })
            let currents = s.history.samples.map(\.current)
            print("T2 list: phase \(String(describing: s.sequence?.phase)) step \(String(describing: s.sequence?.step)) psuMax \(psuMax) samples \(currents.count)")
            #expect(s.sequence?.step == 4)
            #expect(near(psuMax, 0.5, 0.02))
            #expect(currents.contains { near($0, 0.1, 0.01) } && currents.contains { near($0, 0.3, 0.01) })
            #expect(s.state.triggerSource == srcBefore)
            #expect(try await s.sdl.triggerSource() == srcBefore)
            #expect(try await psu.current() < 0.01)
        }
    }

    @Test func programRunsAndJudgesOnSupply() async throws {
        // 0.5 A supply limit: the CV step pulls the supply into its limit, so it measures ~0.5 A.
        try await withRig(volts: 5, amps: 0.5) { s, psu in
            await s.enterFunction(.program)
            await s.loadProgram()
            var a = ProgramStep()
            a.mode = .cc; a.currentRange = .low; a.voltageRange = .low; a.level = 0.2
            a.timeOn = 1; a.timeOff = 0.5; a.timeDelay = 0.5; a.min = 4.5; a.max = 5.5
            var b = a; b.level = 0.4; b.min = 4.0; b.max = 4.5            // expected to fail (≈ 4.97 V)
            var cv = a; cv.mode = .cv; cv.level = 4.0; cv.min = 0.45; cv.max = 0.55
            var c = s.state.program; c.steps = [a, b, cv]; c.stopOnFail = false
            #expect(await s.applyProgram(c))
            #expect(s.state.program.steps.count == 3 && s.state.program.steps[2].mode == .cv)
            try await s.startSequence(.program)
            #expect(await waitFor(15) { s.sequence?.phase == .finished })
            let r = s.sequence?.programResults ?? []
            if r.count != 3 {
                let t0 = s.sequence?.started ?? Date()
                for e in s.log where e.date > t0.addingTimeInterval(-40) && !e.text.hasPrefix("MEAS") {
                    print(String(format: "LOG %+.3f", e.date.timeIntervalSince(t0)), e.kind, e.text)
                }
            }
            print("T2 program: " + r.map { "step \($0.step) \($0.value) \($0.unit) \($0.passed ? "PASS" : "FAIL")" }.joined(separator: "; "))
            #expect(r.count == 3)
            if r.count == 3 {
                #expect(r[0].passed && near(r[0].value, 4.98, 0.03))
                #expect(!r[1].passed)
                #expect(r[2].unit == "A" && near(r[2].value, 0.5, 0.03), "CV step should report current")
            }
            #expect(try await psu.current() < 0.01)
        }
    }

    /// The supply's 0.5 A limit plays the DUT's over-current protection.
    @Test func ocptTripsAtSupplyLimit() async throws {
        try await withRig(volts: 5, amps: 0.5) { s, psu in
            await s.enterFunction(.ocpt)
            await s.loadProtectionTest(.ocpt)
            var c = s.state.ocpt
            c.currentRange = .low; c.voltageRange = .low
            // 4.5 V: the supply in its current limit doesn't always collapse cleanly (it can sit at
            // ~4.1–4.4 V oscillating with the load), so trip on the first clear sag.
            c.start = 0.1; c.step = 0.05; c.stepDelay = 0.3; c.end = 0.8; c.min = 0.4; c.max = 0.6; c.voltage = 4.5
            #expect(await s.applyProtectionTest(.ocpt, c))
            try await s.startSequence(.ocpt)
            #expect(await waitFor(10) { s.sequence?.phase == .finished })
            let r = try #require(s.sequence?.protectionResult)
            print("T2 OCPT: \(r.summary) pass \(r.passed) trace \(s.sequence?.trace.count ?? 0)")
            #expect(r.tripped && r.passed)
            #expect(near(r.value ?? 0, 0.475, 0.05))
            #expect(try await psu.current() < 0.01)
        }
    }

    @Test func ocptWithoutTripOnSupply() async throws {
        try await withRig(volts: 5, amps: 0.5) { s, _ in
            await s.enterFunction(.ocpt)
            await s.loadProtectionTest(.ocpt)
            var c = s.state.ocpt
            c.currentRange = .low; c.start = 0.1; c.step = 0.1; c.stepDelay = 0.3; c.end = 0.3; c.min = 0.4; c.max = 0.6; c.voltage = 3
            await s.applyProtectionTest(.ocpt, c)
            try await s.startSequence(.ocpt)
            #expect(await waitFor(8) { s.sequence?.phase == .finished })
            let r = try #require(s.sequence?.protectionResult)
            print("T2 OCPT no-trip: \(r.summary)")
            if let run = s.sequence {
                for m in run.trace { print(String(format: "TRACE %.3f V=%.4f I=%.4f", m.date.timeIntervalSince(run.started), m.voltage, m.current)) }
                print("ENDED", run.ended.map { $0.timeIntervalSince(run.started) } ?? -1)
            }
            #expect(!r.tripped && !r.passed)
        }
    }

    @Test func opptTripsAtSupplyLimit() async throws {
        try await withRig(volts: 5, amps: 0.5) { s, psu in
            await s.enterFunction(.oppt)
            #expect(s.state.function == .oppt)
            await s.loadProtectionTest(.oppt)
            var c = s.state.oppt
            c.currentRange = .low; c.voltageRange = .low
            c.start = 0.5; c.step = 0.25; c.stepDelay = 0.3; c.end = 3.5; c.min = 2.0; c.max = 3.0; c.voltage = 4.5
            await s.applyProtectionTest(.oppt, c)
            try await s.startSequence(.oppt)
            #expect(await waitFor(10) { s.sequence?.phase == .finished })
            let r = try #require(s.sequence?.protectionResult)
            print("T2 OPPT: \(r.summary) pass \(r.passed)")
            #expect(r.tripped && r.passed && r.unit == "W")
            #expect(try await psu.current() < 0.01)
        }
    }

    /// Ext: settings only (no control voltage on this bench; the input stays off).
    @Test func extSettingsReadBack() async throws {
        try await withRig(volts: 5, amps: 0.5) { s, _ in
            await s.setExternal(mode: .externalCurrent, currentRange: .low, voltageRange: .low)
            #expect(s.state.externalMode == .externalCurrent && s.state.function == .ext)
            #expect(s.state.extCurrentRange == .low && s.state.extVoltageRange == .low)
            await s.refreshExtControlVoltage()
            print("T2 ext: control voltage \(String(describing: s.state.extControlVoltage)) input \(s.state.inputOn)")
            #expect(s.state.extControlVoltage != nil)
            #expect(!s.state.inputOn)
            await s.enterFunction(.basic)
            #expect(s.state.externalMode == .internalControl && s.state.function == .basic)
        }
    }
}
