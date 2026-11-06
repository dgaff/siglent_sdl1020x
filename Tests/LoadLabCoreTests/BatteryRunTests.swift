import Foundation
import Testing
@testable import LoadLabCore
import SDLKit
import SCPIKit
import SDLSimulator

@Suite struct IntegratorTests {
    @Test func constantCurrentForAnHour() {
        var g = Integrator()
        let t0 = Date()
        for k in 0...3600 { g.add(date: t0.addingTimeInterval(Double(k)), current: 1, power: 4) }
        #expect(abs(g.capacity_mAh - 1000) < 1e-6)
        #expect(abs(g.energy_Wh - 4) < 1e-9)
    }

    @Test func seededResumeBridgesGap() {
        var g = Integrator(capacity_mAh: 100, energy_Wh: 1)
        let t0 = Date()
        g.seed(date: t0, current: 2, power: 8)
        g.add(date: t0.addingTimeInterval(36), current: 2, power: 8)   // 2 A × 36 s = 20 mAh
        #expect(abs(g.capacity_mAh - 120) < 1e-9)
    }

    @Test func endReasonInference() {
        var c = BatteryConfig()
        c.stopVoltageEnabled = true; c.stopVoltage = 3.0
        #expect(RunRecorder.inferEndReason(config: c, lastVoltage: 3.01, deviceCapacity: 5, deviceTime: 9) == .voltageCutoff)
        // Steep knee: last loaded sample 3.17 V, then it collapsed; resting voltage 2.74 V.
        #expect(RunRecorder.inferEndReason(config: c, lastVoltage: 3.17, deviceCapacity: 5, deviceTime: 9, restingVoltage: 2.74) == .voltageCutoff)
        #expect(RunRecorder.inferEndReason(config: c, lastVoltage: 3.9, deviceCapacity: 5, deviceTime: 9, restingVoltage: 4.0) == .inputSwitchedOff)
        c.stopVoltageEnabled = false; c.stopCapacityEnabled = true; c.stopCapacity = 100
        #expect(RunRecorder.inferEndReason(config: c, lastVoltage: 3.5, deviceCapacity: 100, deviceTime: 9) == .capacityLimit)
        #expect(RunRecorder.inferEndReason(config: c, lastVoltage: 3.5, deviceCapacity: 40, deviceTime: 9) == .inputSwitchedOff)
    }
}

@MainActor @Suite(.serialized) struct BatteryRunTests {
    func tempStore() -> RunStore {
        RunStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("loadlab-tests-\(UUID().uuidString)"))
    }

    func session(port: UInt16, store: RunStore) async -> DeviceSession {
        let s = DeviceSession(host: "127.0.0.1", port: port)
        s.idlePollInterval = .milliseconds(100)
        s.pollInterval = .milliseconds(100)
        s.runStore = store
        await s.connect()
        return s
    }

    func waitUntil(_ timeout: Duration = .seconds(10), _ cond: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    /// 10 mAh "cell", 4.2 V → 3.0 V; 6 A drains it in ~6 s.
    func cellSim() async throws -> SDLSimulator {
        let sim = SDLSimulator()
        try await sim.start()
        _ = sim.execute(line: "SIM:BATTERY 10,4.2,3.0")
        sim.sourceResistance = 0.02
        return sim
    }

    func ccConfig(_ amps: Double) -> BatteryConfig {
        var c = BatteryConfig()
        c.mode = .cc; c.currentRange = .high; c.voltageRange = .low; c.level = amps
        return c
    }

    @Test func runEndsAtVoltageCutoffAndRestoresVOn() async throws {
        let sim = try await cellSim(); defer { sim.stop() }
        let store = tempStore()
        let s = await session(port: sim.port, store: store)
        await s.setVOn(0.5); await s.setVOnLatch(true)        // user's own settings
        var c = ccConfig(6); c.stopVoltageEnabled = true; c.stopVoltage = 3.3
        var cell = CellInfo(); cell.name = "Sim cell"; cell.nominalCapacity_mAh = 10
        var opts = RecordingOptions(); opts.sampleRateHz = 10
        try await s.startBatteryRun(config: c, cell: cell, options: opts)
        #expect(s.state.inputOn)
        #expect(s.state.vOn == 3.2 && s.state.vOnLatch == false)   // hardware cut-off armed
        let r = try #require(s.recorder)
        #expect(await waitUntil(.seconds(15)) { !r.isActive })
        #expect(r.info.status == .completed)
        #expect(r.info.endReason == .voltageCutoff)
        #expect(s.state.vOn == 0.5 && s.state.vOnLatch == true)    // restored
        #expect(r.samples.count > 20)
        let dev = r.info.summary.deviceCapacity_mAh ?? -1
        #expect(abs(r.info.summary.capacity_mAh - dev) < 1.5, "app \(r.info.summary.capacity_mAh) vs device \(dev)")
        // A fresh 10 mAh cell must deliver close to its capacity before cut-off.
        #expect(r.info.summary.capacity_mAh > 7 && r.info.summary.capacity_mAh < 11)
        // Files on disk
        let csv = try String(contentsOf: r.folder.appendingPathComponent("samples.csv"), encoding: .utf8)
        #expect(csv.hasPrefix(RunStore.csvHeader))
        #expect(csv.split(separator: "\n").count == r.samples.count + 1)
        let saved = try store.load(r.folder)
        #expect(saved.status == .completed && saved.cell.name == "Sim cell")
        #expect(store.loadSamples(r.folder).count == r.samples.count)
        await s.disconnect()
    }

    @Test func userStop() async throws {
        let sim = try await cellSim(); defer { sim.stop() }
        let s = await session(port: sim.port, store: tempStore())
        var c = ccConfig(0.5); c.stopTimeEnabled = true; c.stopTime = 600
        try await s.startBatteryRun(config: c, cell: CellInfo(), options: RecordingOptions())
        try await Task.sleep(for: .seconds(1.2))
        await s.stopRun()
        let r = try #require(s.recorder)
        #expect(r.info.status == .stopped && r.info.endReason == .userStopped)
        #expect(!s.state.inputOn)
        await s.disconnect()
    }

    @Test func refusesWithoutStopCondition() async throws {
        let sim = try await cellSim(); defer { sim.stop() }
        let s = await session(port: sim.port, store: tempStore())
        await #expect(throws: DeviceSession.RunStartError.noStopCondition) {
            try await s.startBatteryRun(config: self.ccConfig(1), cell: CellInfo(), options: RecordingOptions())
        }
        #expect(!s.state.inputOn)
        await s.disconnect()
    }

    @Test func resumesAfterAppRestart() async throws {
        let sim = try await cellSim(); defer { sim.stop() }
        _ = sim.execute(line: "SIM:BATTERY 1000,4.2,3.0")      // long-lived cell
        let store = tempStore()
        let a = await session(port: sim.port, store: store)
        var c = ccConfig(1); c.stopTimeEnabled = true; c.stopTime = 600
        try await a.startBatteryRun(config: c, cell: CellInfo(), options: RecordingOptions())
        try await Task.sleep(for: .seconds(1.5))
        let before = try #require(a.recorder).integrator.capacity_mAh
        await a.disconnect()                                    // "app quits"; instrument keeps going
        try await Task.sleep(for: .seconds(1))

        let b = await session(port: sim.port, store: store)     // "app relaunches"
        await b.resumeInterruptedRuns()
        let r = try #require(b.recorder)
        #expect(r.isActive)
        #expect(r.info.events.contains { $0.kind == "resume" })
        try await Task.sleep(for: .seconds(1))
        // Capacity continued from the saved total and bridged the ~1 s gap.
        #expect(r.integrator.capacity_mAh > before + 0.5)
        await b.stopRun()
        await b.disconnect()
    }

    @Test func runThatEndedWhileAwayIsClosedWithDeviceCounters() async throws {
        let sim = try await cellSim(); defer { sim.stop() }
        _ = sim.execute(line: "SIM:BATTERY 1000,4.2,3.0")
        let store = tempStore()
        let a = await session(port: sim.port, store: store)
        var c = ccConfig(3); c.stopTimeEnabled = true; c.stopTime = 600
        try await a.startBatteryRun(config: c, cell: CellInfo(), options: RecordingOptions())
        try await Task.sleep(for: .seconds(1))
        await a.disconnect()
        try await Task.sleep(for: .seconds(1.5))
        _ = sim.execute(line: ":INP OFF")                       // ended while LoadLab was away

        let b = await session(port: sim.port, store: store)
        await b.resumeInterruptedRuns()
        let r = try #require(b.recorder)
        #expect(!r.isActive)
        #expect(r.info.status == .interrupted && r.info.endReason == .endedWhileDisconnected)
        #expect((r.info.summary.deviceCapacity_mAh ?? 0) >= 1)
        let stillRunning = store.runningRuns(serial: b.identity?.serial)
        #expect(stillRunning.isEmpty)
        await b.disconnect()
    }

    /// Regression: a status check that read the input *before* the run switched it on used to
    /// end the run on that stale "off" (seen with the simulator demo; profiles on hardware).
    @Test func staleStatusDoesNotEndANewRun() async throws {
        let sim = SDLSimulator()
        try await sim.start(); defer { sim.stop() }
        _ = sim.execute(line: "SIM:BATTERY 5000,4.2,3.0")
        sim.queryCost = 0.04          // a status check (~8 queries) now spans ~1/3 of each second
        let store = tempStore()
        let s = await session(port: sim.port, store: store)
        var early = 0
        for k in 0..<6 {
            try await Task.sleep(for: .milliseconds(137 * k % 900))
            var c = ccConfig(0.5); c.stopVoltageEnabled = true; c.stopVoltage = 3.0
            var o = RecordingOptions(); o.sampleRateHz = 10
            try await s.startBatteryRun(config: c, cell: CellInfo(), options: o)
            try await Task.sleep(for: .milliseconds(1500))
            if s.recorder?.isActive != true { early += 1 }
            await s.stopRun()
            s.dismissRun()
        }
        #expect(early == 0, "\(early) of 6 runs ended on a stale status reading")
        await s.disconnect()
    }
}
