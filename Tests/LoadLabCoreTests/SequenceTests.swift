import Foundation
import Testing
@testable import LoadLabCore
import SDLKit
import SCPIKit
import SDLSimulator

@Suite struct SequenceModelTests {
    @Test func listCSVRoundTrip() throws {
        let steps = [ListStep(level: 0.1, width: 1, slew: 0.5), ListStep(level: 2.25, width: 0.02, slew: 0.1)]
        let text = StepCSV.list(steps)
        #expect(text.hasPrefix(StepCSV.listHeader))
        let back = try StepCSV.parseList(text)
        #expect(back.count == 2 && back[1].sameValues(as: steps[1]))
        // Header-less, comments, missing slew.
        let loose = try StepCSV.parseList("# my list\n0.5, 2\n1,3,0.2\n")
        #expect(loose.map(\.level) == [0.5, 1] && loose[0].slew == 0.5)
        #expect(throws: StepCSV.CSVError.self) { try StepCSV.parseList("abc,def\n1\n") }
    }

    @Test func programCSVRoundTrip() throws {
        var a = ProgramStep(); a.mode = .cv; a.level = 4.2; a.min = 0.1; a.max = 0.3; a.short = true
        var b = ProgramStep(); b.mode = .led; b.ledCurrent = 0.35; b.ledRco = 0.3
        let back = try StepCSV.parseProgram(StepCSV.program([a, b]))
        #expect(back.count == 2 && back[0].sameValues(as: a) && back[1].sameValues(as: b))
    }

    @Test func protectionAnalysis() {
        var c = ProtectionTestConfig()
        c.start = 0.1; c.step = 0.05; c.stepDelay = 0.3; c.end = 0.8; c.min = 0.4; c.max = 0.6; c.voltage = 3
        func r(_ v: Double, _ i: Double) -> Reading { .derived(voltage: v, current: i) }
        let trip = ProtectionResult.analyse(trace: [r(5, 0.1), r(4.99, 0.3), r(4.97, 0.45), r(1.2, 0.5), r(5, 0)], config: c, isPower: false)
        #expect(trip.tripped && abs((trip.value ?? 0) - 0.45) < 1e-9 && trip.passed)
        // Ramp reached the end without collapsing: no trip, so it fails.
        let none = ProtectionResult.analyse(trace: [r(5, 0.1), r(4.95, 0.8), r(5, 0)], config: c, isPower: false)
        #expect(!none.tripped && !none.passed)
        // Stopped short of the end (collapse missed between samples) still counts as a trip.
        let missed = ProtectionResult.analyse(trace: [r(5, 0.2), r(4.97, 0.35), r(5, 0)], config: c, isPower: false)
        #expect(missed.tripped && !missed.passed)          // 0.35 is below the 0.4 minimum
        // Hardware: the ramp stops before applying End (0.1, 0.2 applied; End 0.3) → no trip.
        var d = c; d.step = 0.1; d.end = 0.3
        let shortRamp = ProtectionResult.analyse(trace: [r(5, 0.1), r(4.99, 0.2), r(4.99, 0.12), r(5, 0)], config: d, isPower: false)
        #expect(!shortRamp.tripped)
        // A real DUT stays collapsed after the trip (current gone): still a trip.
        let dut = ProtectionResult.analyse(trace: [r(5, 0.3), r(4.9, 0.6), r(0.1, 0), r(0.1, 0)], config: d, isPower: false)
        #expect(dut.tripped)
    }

    @Test func validation() {
        var l = ListConfig(); l.mode = .cc; l.currentRange = .low
        l.steps = [ListStep(level: 6, width: 1)]
        #expect(!l.validate().isEmpty)
        var p = ProgramConfig(); p.steps[0].min = 5; p.steps[0].max = 1
        #expect(p.validate().contains { $0.contains("min is above max") })
        var o = ProtectionTestConfig(); o.start = 1; o.end = 0.5
        #expect(!o.validate(isPower: false).isEmpty)
    }
}

@MainActor @Suite(.serialized) struct SequenceRunTests {
    func session(_ sim: SDLSimulator) async -> DeviceSession {
        let s = DeviceSession(host: "127.0.0.1", port: sim.port)
        s.idlePollInterval = .milliseconds(100)
        s.pollInterval = .milliseconds(100)
        await s.connect()
        return s
    }

    func waitUntil(_ timeout: Duration = .seconds(15), _ cond: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cond()
    }

    func sim(volts: Double = 5, ilim: Double? = nil) async throws -> SDLSimulator {
        let sim = SDLSimulator()
        try await sim.start()
        sim.sourceVoltage = volts
        sim.sourceResistance = 0.05
        if let ilim { _ = sim.execute(line: "SIM:SOURCE:ILIM \(ilim)") }
        return sim
    }

    @Test func listRunsToTheEndAndRestoresTriggerSource() async throws {
        let sim = try await sim(); defer { sim.stop() }
        let s = await session(sim)
        #expect(s.state.triggerSource == .manual)
        await s.enterFunction(.list)
        #expect(s.state.function == .list)
        await s.loadList()
        var c = s.state.list
        c.mode = .cc; c.currentRange = .low; c.count = 2
        c.steps = [ListStep(level: 0.1, width: 0.4), ListStep(level: 0.3, width: 0.4), ListStep(level: 0.5, width: 0.4)]
        #expect(await s.applyList(c))
        #expect(s.state.list.steps.count == 3 && s.state.list.count == 2 && abs(s.state.list.steps[2].level - 0.5) < 1e-9)
        s.clearHistory()
        try await s.startSequence(.list)
        #expect(await waitUntil { s.sequence?.phase == .finished })
        #expect(s.sequence?.step == 4)
        #expect(s.state.triggerSource == .manual)
        #expect(sim.execute(line: "TRIG:SOUR?") == "MANUAL")
        #expect(!s.state.inputOn)
        let currents = s.history.samples.map(\.current)
        #expect(currents.contains { abs($0 - 0.5) < 0.01 } && currents.contains { abs($0 - 0.1) < 0.01 })
        await s.disconnect()
    }

    @Test func applyWritesOnlyWhatChanged() async throws {
        let sim = try await sim(); defer { sim.stop() }
        let s = await session(sim)
        await s.enterFunction(.list)
        await s.loadList()
        var c = s.state.list
        c.steps = (1...5).map { ListStep(level: Double($0) / 10, width: 1) }
        await s.applyList(c)
        s.clearLog()
        c.steps[3].level = 0.45
        await s.applyList(c)
        let writes = s.log.filter { $0.kind == .write && $0.text.hasPrefix(":LIST:") }.map(\.text)
        #expect(writes == [":LIST:LEV 4,0.45"], "\(writes)")
        await s.disconnect()
    }

    @Test func stoppingAListRestoresTriggerSource() async throws {
        let sim = try await sim(); defer { sim.stop() }
        let s = await session(sim)
        await s.enterFunction(.list)
        await s.loadList()
        var c = s.state.list
        c.mode = .cc; c.currentRange = .low; c.count = 5; c.steps = [ListStep(level: 0.2, width: 2)]
        await s.applyList(c)
        try await s.startSequence(.list)
        #expect(await waitUntil { s.latest.map { abs($0.current - 0.2) < 0.01 } ?? false })
        await s.stopSequence()
        #expect(s.sequence?.phase == .stopped)
        #expect(sim.execute(line: "TRIG:SOUR?") == "MANUAL" && sim.execute(line: ":INP?") == "0")
        await s.disconnect()
    }

    /// The instrument clamps min ≤ max (and start ≤ end) as each is written (measured), so
    /// moving a window above the old one needs max written first.
    @Test func clampedPairsAreWrittenInOrder() async throws {
        let sim = try await sim(); defer { sim.stop() }
        let s = await session(sim)
        await s.enterFunction(.program)
        await s.loadProgram()
        var c = s.state.program
        c.steps[0].min = 0.45; c.steps[0].max = 0.55
        await s.applyProgram(c)
        c = s.state.program
        c.steps[0].min = 7; c.steps[0].max = 9           // entirely above the old window
        await s.applyProgram(c)
        #expect(s.state.program.steps[0].min == 7 && s.state.program.steps[0].max == 9, "\(s.state.program.steps[0].summary)")
        c.steps[0].min = 0.1; c.steps[0].max = 0.2       // entirely below
        await s.applyProgram(c)
        #expect(s.state.program.steps[0].min == 0.1 && s.state.program.steps[0].max == 0.2)

        await s.enterFunction(.ocpt)
        await s.loadProtectionTest(.ocpt)
        var o = s.state.ocpt
        o.start = 2; o.end = 3; o.min = 2; o.max = 3; o.step = 0.1; o.stepDelay = 0.1; o.voltage = 1
        await s.applyProtectionTest(.ocpt, o)
        o.start = 0.1; o.end = 0.5; o.min = 0.2; o.max = 0.4
        await s.applyProtectionTest(.ocpt, o)
        #expect(s.state.ocpt == o, "\(s.state.ocpt)")
        await s.disconnect()
    }

    @Test func programCollectsResultsAndJudgesThem() async throws {
        let sim = try await sim(); defer { sim.stop() }
        let s = await session(sim)
        await s.enterFunction(.program)
        await s.loadProgram()
        var a = ProgramStep()
        a.mode = .cc; a.currentRange = .low; a.voltageRange = .low; a.level = 0.2
        a.timeOn = 0.5; a.timeOff = 0.3; a.timeDelay = 0.25; a.min = 4.5; a.max = 5.5
        var b = a; b.level = 0.4; b.min = 4.9; b.max = 4.95
        var c = s.state.program; c.steps = [a, b]
        #expect(await s.applyProgram(c))
        #expect(s.state.program.steps.count == 2 && abs(s.state.program.steps[1].level - 0.4) < 1e-9)
        try await s.startSequence(.program)
        #expect(await waitUntil { s.sequence?.phase == .finished })
        let r = try #require(s.sequence?.programResults)
        #expect(r.count == 2)
        #expect(r[0].passed && abs(r[0].value - 4.99) < 0.005, "\(r)")
        #expect(!r[1].passed && abs(r[1].value - 4.98) < 0.005, "\(r)")
        await s.disconnect()
    }

    @Test func ocptFindsTheTripPoint() async throws {
        let sim = try await sim(ilim: 0.5); defer { sim.stop() }
        let s = await session(sim)
        await s.enterFunction(.ocpt)
        await s.loadProtectionTest(.ocpt)
        var c = s.state.ocpt
        c.currentRange = .low; c.start = 0.1; c.step = 0.05; c.stepDelay = 0.2; c.end = 0.8; c.min = 0.4; c.max = 0.6; c.voltage = 3
        #expect(await s.applyProtectionTest(.ocpt, c))
        try await s.startSequence(.ocpt)
        #expect(await waitUntil { s.sequence?.phase == .finished })
        let r = try #require(s.sequence?.protectionResult)
        #expect(r.tripped && r.passed, "\(r.summary)")
        #expect(abs((r.value ?? 0) - 0.45) < 0.051, "\(r.summary)")
        #expect(!s.state.inputOn)
        await s.disconnect()
    }

    @Test func stalledOCPTIsStoppedByLoadLab() async throws {
        let sim = try await sim(); defer { sim.stop() }
        _ = sim.execute(line: "SIM:OCP:STALL 1")
        let s = await session(sim)
        await s.enterFunction(.ocpt)
        await s.loadProtectionTest(.ocpt)
        var c = s.state.ocpt
        c.currentRange = .low; c.start = 0.1; c.step = 0.1; c.stepDelay = 0.2; c.end = 0.3; c.min = 0.4; c.max = 0.6; c.voltage = 3
        await s.applyProtectionTest(.ocpt, c)
        try await s.startSequence(.ocpt)
        // Longest ramp 0.6 s + 3 s grace, checked once a second.
        #expect(await waitUntil(.seconds(8)) { s.sequence?.phase == .stopped })
        #expect(s.sequence?.note != nil)
        #expect(sim.execute(line: ":INP?") == "0")
        await s.disconnect()
    }

    @Test func ocptWithoutTripFails() async throws {
        let sim = try await sim(ilim: 0.5); defer { sim.stop() }
        let s = await session(sim)
        await s.enterFunction(.ocpt)
        await s.loadProtectionTest(.ocpt)
        var c = s.state.ocpt
        c.currentRange = .low; c.start = 0.1; c.step = 0.1; c.stepDelay = 0.2; c.end = 0.3; c.min = 0.4; c.max = 0.6; c.voltage = 3
        await s.applyProtectionTest(.ocpt, c)
        try await s.startSequence(.ocpt)
        #expect(await waitUntil { s.sequence?.phase == .finished })
        let r = try #require(s.sequence?.protectionResult)
        #expect(!r.tripped && !r.passed, "\(r.summary)")
        await s.disconnect()
    }

    @Test func opptFindsTheTripPower() async throws {
        let sim = try await sim(ilim: 0.5); defer { sim.stop() }
        let s = await session(sim)
        await s.enterFunction(.oppt)
        #expect(s.state.function == .oppt)
        await s.loadProtectionTest(.oppt)
        var c = s.state.oppt
        c.currentRange = .low; c.start = 0.5; c.step = 0.25; c.stepDelay = 0.2; c.end = 3.5; c.min = 2; c.max = 3; c.voltage = 3
        await s.applyProtectionTest(.oppt, c)
        try await s.startSequence(.oppt)
        #expect(await waitUntil { s.sequence?.phase == .finished })
        let r = try #require(s.sequence?.protectionResult)
        #expect(r.tripped && r.passed && r.unit == "W", "\(r.summary)")
        await s.disconnect()
    }

    @Test func extModeAndRanges() async throws {
        let sim = try await sim(); defer { sim.stop() }
        let s = await session(sim)
        await s.setExternal(mode: .externalCurrent, currentRange: .low, voltageRange: .low)
        #expect(s.state.externalMode == .externalCurrent && s.state.function == .ext)
        #expect(s.state.extCurrentRange == .low && s.state.extVoltageRange == .low)
        await s.refreshExtControlVoltage()
        #expect(s.state.extControlVoltage == 0)
        await s.enterFunction(.basic)
        #expect(s.state.externalMode == .internalControl && s.state.function == .basic)
        await s.disconnect()
    }
}
