import Foundation
import Testing
@testable import LoadLabCore
import SDLKit
import SCPIKit
import SDLSimulator

@Suite struct ProfileModelTests {
    func cell() -> CellInfo {
        var c = CellInfo(); c.name = "Test 18650"; c.nominalCapacity_mAh = 2500; c.nominalVoltage = 3.6
        return c
    }

    @Test func templatesAreValidAndRespectTheCurrentCap() {
        for t in ProfileTemplate.allCases {
            let p = t.make(cell: cell(), maxCurrent: 0.9)
            #expect(p.validate().isEmpty, "\(t): \(p.validate())")
            #expect(p.maxCCLevel <= 0.9, "\(t) draws \(p.maxCCLevel) A")
            #expect(p.limits.cutoffVoltage == 3.0)
            #expect(p.currentRange == .low && p.voltageRange == .low)
        }
        // CP is sized at the cut-off, so its worst-case current stays under the cap.
        let cp = ProfileTemplate.constantPower.make(cell: cell(), maxCurrent: 0.9)
        let watts = cp.steps[0].level
        #expect(watts / cp.limits.cutoffVoltage <= 0.9)
    }

    @Test func validationCatchesProblems() {
        var p = Profile(name: "x", steps: [.rest(10)])
        #expect(p.validate().contains { $0.contains("loads the cell") })
        p.steps = [.hold(.cc, 2.0)]
        p.limits.maxCurrent = 1
        #expect(p.validate().contains { $0.contains("above the 1 A limit") })
        p.steps = [.hold(.cc, 0.5, untilVoltage: 2.9)]
        #expect(p.validate().contains { $0.contains("above the cut-off") })
        p.steps = [.pulse(.cc, high: 0.5, highSeconds: 0.2, low: 0.1, lowSeconds: 1, count: 3)]
        #expect(p.validate().contains { $0.contains("at least 1 s") })
        p.steps = [.dcr(i1: 0.3, t1: 5, i2: 0.3, t2: 1)]
        #expect(p.validate().contains { $0.contains("must differ") })
        p.steps = [.loop([.rest(5)])]
        #expect(!p.validate().isEmpty)
        p.steps = [.hold(.cc, 0.5)]
        p.limits.cutoffVoltage = 0
        #expect(p.validate().contains { $0.contains("cut-off voltage above 0") })
    }

    @Test func profileRoundTripsAsJSON() throws {
        let p = ProfileTemplate.hppc.make(cell: cell())
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        #expect(back == p)
        #expect(back.steps[0].children.count == 3)
    }

    @Test func oldRunJSONStillDecodes() throws {
        // A Phase 3/4 run.json has no profile fields.
        let info = RunInfo(title: "old", cell: CellInfo(), battery: BatteryConfig(), options: RecordingOptions(), startedAt: Date())
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as! [String: Any]
        obj["profile"] = nil; obj["dcrResults"] = nil; obj["savedBasic"] = nil
        let data = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(RunInfo.self, from: data)
        #expect(back.profile == nil && back.dcrResults == nil)
    }
}

/// Profile runs against the simulator (T0). Real time, so durations are kept short.
@MainActor @Suite(.serialized) struct ProfileRunTests {
    func tempStore() -> RunStore {
        RunStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("loadlab-prof-\(UUID().uuidString)"))
    }

    func session(_ sim: SDLSimulator, store: RunStore) async -> DeviceSession {
        let s = DeviceSession(host: "127.0.0.1", port: sim.port)
        s.idlePollInterval = .milliseconds(100)
        s.pollInterval = .milliseconds(100)
        s.runStore = store
        await s.connect()
        return s
    }

    func waitUntil(_ timeout: Duration = .seconds(20), _ cond: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    func sim(capacity: Double, rs: Double = 0.05) async throws -> SDLSimulator {
        let sim = SDLSimulator()
        try await sim.start()
        _ = sim.execute(line: "SIM:BATTERY \(capacity),4.2,3.0")
        sim.sourceResistance = rs
        return sim
    }

    func profile(_ steps: [ProfileStep], cutoff: Double = 3.0, maxCurrent: Double = 1.0) -> Profile {
        var p = Profile(name: "Test profile", steps: steps)
        p.limits.cutoffVoltage = cutoff
        p.limits.maxCurrent = maxCurrent
        p.sampleRateHz = 10
        return p
    }

    var cell: CellInfo { var c = CellInfo(); c.name = "Sim cell"; return c }

    @Test func runsStepsMeasuresDCRAndRestoresSettings() async throws {
        let sim = try await sim(capacity: 500, rs: 0.05); defer { sim.stop() }
        let s = await session(sim, store: tempStore())
        // The user's own settings, which the profile must put back.
        await s.setLevel(.cc, 0.25)
        await s.setVOn(0.5); await s.setVOnLatch(true)
        await s.setMode(.cv)
        let p = profile([
            .mark("Start"),
            .hold(.cc, 0.2, duration: 1.0),
            .rest(1.0),
            .dcr(i1: 0.1, t1: 1.0, i2: 0.6, t2: 1.0),
            .pulse(.cc, high: 0.5, highSeconds: 1, low: 0.1, lowSeconds: 1, count: 2),
        ])
        try await s.startProfileRun(p, cell: cell)
        let r = try #require(s.recorder)
        #expect(s.state.vOn == 2.9 && s.state.vOnLatch == false)       // failsafe armed
        #expect(s.preventingSleep)
        #expect(await waitUntil { !r.isActive })
        #expect(r.info.status == .completed && r.info.endReason == .profileFinished)
        let dcr = try #require(r.info.dcrResults?.first)
        #expect(abs(dcr.milliohms - 50) < 5, "DCR \(dcr.milliohms) mΩ")
        #expect(r.info.events.filter { $0.kind == "step" }.count == 4)
        #expect(r.info.events.contains { $0.kind == "mark" && $0.text == "Start" })
        // Pulses: both levels show up in the recording.
        let currents = r.samples.map(\.current)
        #expect(currents.contains { abs($0 - 0.5) < 0.01 } && currents.contains { abs($0 - 0.1) < 0.01 })
        // Everything put back.
        #expect(s.state.inputOn == false)
        #expect(s.state.vOn == 0.5 && s.state.vOnLatch == true)
        #expect(abs(s.state[mode: .cc].level - 0.25) < 1e-6)
        #expect(s.state.mode == .cv)
        #expect(!s.preventingSleep)
        // run.json has the profile and the result.
        let saved = try s.runStore.load(r.folder)
        #expect(saved.kind == "profile" && saved.profile?.steps == p.steps && saved.dcrResults?.count == 1)
        await s.disconnect()
    }

    @Test func cutoffEndsTheProfile() async throws {
        let sim = try await sim(capacity: 2); defer { sim.stop() }
        let s = await session(sim, store: tempStore())
        let p = profile([.hold(.cc, 0.8)], cutoff: 3.3)
        try await s.startProfileRun(p, cell: cell)
        let r = try #require(s.recorder)
        #expect(await waitUntil(.seconds(30)) { !r.isActive })
        #expect(r.info.endReason == .voltageCutoff, "\(String(describing: r.info.endReason))")
        #expect(s.state.inputOn == false)
        #expect(sim.execute(line: ":INP?") == "0")
        await s.disconnect()
    }

    @Test func loopEndsOnCapacity() async throws {
        let sim = try await sim(capacity: 500); defer { sim.stop() }
        let s = await session(sim, store: tempStore())
        // 0.9 A for 0.5 s ≈ 0.125 mAh per pass; stop after 0.3 mAh → 3 passes.
        let p = profile([.loop([.hold(.cc, 0.9, duration: 0.5), .rest(0.3)], count: 20, untilCapacity: 0.3)])
        try await s.startProfileRun(p, cell: cell)
        let r = try #require(s.recorder)
        #expect(await waitUntil { !r.isActive })
        let passes = r.info.events.filter { $0.kind == "loop" }.count
        #expect(passes >= 2 && passes <= 4, "passes \(passes)")
        #expect(r.info.endReason == .profileFinished)
        await s.disconnect()
    }

    @Test func overCurrentIsStopped() async throws {
        let sim = try await sim(capacity: 500); defer { sim.stop() }
        let s = await session(sim, store: tempStore())
        // CR 2 Ω at ~4 V draws ~2 A, over the 1 A limit.
        let p = profile([.hold(.cr, 2.0, duration: 10)])
        try await s.startProfileRun(p, cell: cell)
        let r = try #require(s.recorder)
        #expect(await waitUntil(.seconds(5)) { !r.isActive })
        #expect(r.info.endReason == .currentLimit)
        #expect(sim.execute(line: ":INP?") == "0")
        await s.disconnect()
    }

    @Test func unexpectedInputOffEndsTheProfile() async throws {
        let sim = try await sim(capacity: 500); defer { sim.stop() }
        let s = await session(sim, store: tempStore())
        try await s.startProfileRun(profile([.hold(.cc, 0.3, duration: 30)]), cell: cell)
        let r = try #require(s.recorder)
        #expect(await waitUntil { s.state.inputOn })
        _ = sim.execute(line: ":INP OFF")                 // "front panel"
        #expect(await waitUntil(.seconds(5)) { !r.isActive })
        #expect(r.info.endReason == .inputSwitchedOff)
        await s.disconnect()
    }

    @Test func droppedConnectionSwitchesInputOffOnReconnect() async throws {
        let sim = try await sim(capacity: 500); defer { sim.stop() }
        let s = await session(sim, store: tempStore())
        try await s.startProfileRun(profile([.hold(.cc, 0.3, duration: 60)]), cell: cell)
        let r = try #require(s.recorder)
        #expect(await waitUntil { s.state.inputOn })
        sim.dropClients()
        #expect(await waitUntil(.seconds(20)) { !r.isActive })
        #expect(r.info.endReason == .connectionLost)
        #expect(sim.execute(line: ":INP?") == "0")
        #expect(r.info.events.contains { $0.kind == "reconnect" })
        await s.disconnect()
    }

    /// Hardware-like command latency. On the real SDL a status poll read the input just before
    /// the runner switched it on and then ended the run on that stale reading (fixed with
    /// `inputGeneration`). The simulator doesn't hit that timing reliably; the hardware test
    /// `profileRunOnSupply` does (it failed every time without the fix).
    @Test func slowInstrumentDoesNotFalselyEndTheRun() async throws {
        let sim = try await sim(capacity: 500); defer { sim.stop() }
        sim.writeCost = 0.12
        sim.queryCost = 0.03
        let s = await session(sim, store: tempStore())
        let p = profile([
            .hold(.cc, 0.3, duration: 1.5), .rest(1),
            .pulse(.cc, high: 0.5, highSeconds: 1, low: 0.1, lowSeconds: 1, count: 2),
            .hold(.cp, 1.0, duration: 1.5),
        ])
        try await s.startProfileRun(p, cell: cell)
        let r = try #require(s.recorder)
        #expect(await waitUntil(.seconds(40)) { !r.isActive })
        #expect(r.info.endReason == .profileFinished, "\(String(describing: r.info.endReason))")
        await s.disconnect()
    }

    @Test func refusesToStartBelowCutoff() async throws {
        let sim = try await sim(capacity: 500); defer { sim.stop() }
        let s = await session(sim, store: tempStore())
        await s.setLevel(.cc, 0.25)
        await #expect(throws: DeviceSession.ProfileStartError.self) {
            try await s.startProfileRun(self.profile([.hold(.cc, 0.3)], cutoff: 4.5), cell: self.cell)
        }
        #expect(s.recorder == nil)
        #expect(abs(s.state[mode: .cc].level - 0.25) < 1e-6)
        #expect(sim.execute(line: ":INP?") == "0")
        await s.disconnect()
    }

    @Test func interruptedProfileIsSwitchedOffOnNextConnect() async throws {
        let sim = try await sim(capacity: 500); defer { sim.stop() }
        let store = tempStore()
        let s = await session(sim, store: store)
        await s.setVOn(0.5); await s.setVOnLatch(true)
        try await s.startProfileRun(profile([.hold(.cc, 0.3, duration: 60)]), cell: cell)
        let r = try #require(s.recorder)
        #expect(await waitUntil { s.state.inputOn })
        // "LoadLab quits": the session goes away without ending the run.
        await s.disconnect()
        #expect(sim.execute(line: ":INP?") == "1")
        let s2 = await session(sim, store: store)
        await s2.resumeInterruptedRuns()
        #expect(sim.execute(line: ":INP?") == "0")
        let saved = try store.load(r.folder)
        #expect(saved.status == .interrupted)
        #expect(s2.state.vOn == 0.5 && s2.state.vOnLatch == true)
        await s2.disconnect()
    }
}

@Suite struct ProfileEditingTests {
    @Test func insertMoveRemoveNested() throws {
        var p = Profile(name: "e", steps: [.rest(1), .loop([.hold(.cc, 0.1, duration: 1)], count: 2)])
        let loopID = p.steps[1].id
        let inner = p.steps[1].children[0].id
        p.append(.rest(2), into: loopID)
        #expect(p.steps[1].children.count == 2)
        #expect(p.path(of: inner) == [1, 0])
        p.move(inner, by: 1)
        #expect(p.path(of: inner) == [1, 1])
        var s = try #require(p.step(inner)); s.level = 0.3; p.update(s)
        #expect(p.steps[1].children[1].level == 0.3)
        p.insert(.mark("m"), after: inner)
        #expect(p.steps[1].children.count == 3 && p.steps[1].children[2].kind == .mark)
        p.remove(inner)
        #expect(p.path(of: inner) == nil && p.steps[1].children.count == 2)
        #expect(p.rows.map(\.depth) == [0, 0, 1, 1])
        #expect(p.estimatedDuration(capacity_mAh: nil) == 5, "\(String(describing: p.estimatedDuration(capacity_mAh: nil))) \(p.rows.map { $0.step.summary })")
    }

    @Test func storeRoundTrip() throws {
        let store = ProfileStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("loadlab-profiles-\(UUID().uuidString)"))
        var p = ProfileTemplate.pulse.make(cell: CellInfo())
        p.name = "Mine"
        try store.save(p)
        #expect(store.all().map(\.name) == ["Mine"])
        try store.delete(p)
        #expect(store.all().isEmpty)
    }
}
