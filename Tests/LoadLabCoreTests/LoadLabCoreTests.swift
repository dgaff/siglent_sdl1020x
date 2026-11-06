import Foundation
import Testing
@testable import LoadLabCore
import SDLKit
import SCPIKit
import SDLSimulator

@MainActor @Suite(.serialized) struct DeviceSessionTests {
    func withSession(_ body: (SDLSimulator, DeviceSession) async throws -> Void) async throws {
        let sim = SDLSimulator()
        sim.sourceVoltage = 12; sim.sourceResistance = 0.1
        let port = try await sim.start()
        let s = DeviceSession(host: "127.0.0.1", port: port)
        s.pollInterval = .milliseconds(50)
        await s.connect()
        #expect(s.link == .connected)
        try await body(sim, s)
        await s.disconnect()
        sim.stop()
    }

    func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return cond()
    }

    @Test func connectReadsIdentityAndPolls() async throws {
        try await withSession { _, s in
            #expect(s.identity?.model == "SDL1020X")
            #expect(s.state.function == .basic)
            #expect(await waitUntil { s.history.count >= 3 })
            #expect(s.latest?.voltage == 12)
        }
    }

    @Test func ccLoadAndClamping() async throws {
        try await withSession { _, s in
            await s.setMode(.cc)
            await s.setCurrentRange(.cc, .low)
            await s.setLevel(.cc, 9)                       // clamps to 5 A on the 5 A range
            #expect(s.state[mode: .cc].level == 5)
            await s.setLevel(.cc, 0.5)
            await s.setInput(true)
            #expect(s.state.inputOn)
            #expect(await waitUntil { abs((s.latest?.current ?? 0) - 0.5) < 1e-6 })
            await s.setSlew(.rise, 0.9)                    // > 0.5 on 5 A range → 0.5
            #expect(s.state.slewRise == 0.5)
            await s.emergencyOff()
            #expect(s.state.inputOn == false)
        }
    }

    @Test func modeChangeTurnsInputOff() async throws {
        try await withSession { _, s in
            await s.setInput(true)
            #expect(s.state.inputOn)
            await s.setMode(.cr)
            #expect(s.state.mode == .cr)
            #expect(s.state.inputOn == false)
        }
    }

    @Test func dynamicContinuousAlternates() async throws {
        try await withSession { _, s in
            await s.setMode(.cc)
            await s.setTransient(.cc, .aLevel, 0.2)
            await s.setTransient(.cc, .bLevel, 0.6)
            await s.setTransient(.cc, .aWidth, 0.1)
            await s.setTransient(.cc, .bWidth, 0.1)
            await s.setDynamic(true)
            #expect(s.state.dynamic)
            #expect(s.state.inputOn == false)
            await s.setInput(true)
            try await Task.sleep(for: .milliseconds(800))
            let currents = Set(s.history.samples.suffix(12).map { ($0.current * 10).rounded() / 10 })
            #expect(currents.contains(0.2) && currents.contains(0.6), "saw \(currents)")
            await s.setDynamic(false)
            #expect(!s.state.dynamic && !s.state.inputOn)
        }
    }

    @Test func reconnectsAfterDrop() async throws {
        try await withSession { sim, s in
            #expect(await waitUntil { s.history.count > 2 })
            sim.dropClients()
            #expect(await waitUntil(.seconds(2)) { if case .reconnecting = s.link { true } else { s.link == .connected } })
            #expect(await waitUntil(.seconds(6)) { s.link == .connected })
            let n = s.history.count
            #expect(await waitUntil { s.history.count > n + 2 })
        }
    }

    @Test func busyDeviceReported() async throws {
        let sim = SDLSimulator()
        let port = try await sim.start()
        let first = SCPIConnection(host: "127.0.0.1", port: port)
        try await first.connect()
        _ = try await first.query("*IDN?")
        let s = DeviceSession(host: "127.0.0.1", port: port)
        await s.connect()
        if case .failed(let why) = s.link { #expect(why.contains("in use")) } else { Issue.record("expected failure, got \(s.link)") }
        await first.disconnect()
        sim.stop()
    }

    @Test func detectsFrontPanelFunctionChange() async throws {
        try await withSession { sim, s in
            _ = sim.execute(line: ":BATT:FUNC")           // as if pressed on the front panel
            #expect(await waitUntil { s.state.function == .battery })
            await s.switchToBasic()
            #expect(s.state.function == .basic)
        }
    }
}

@Suite struct HistoryTests {
    @Test func ringBufferWrapsInOrder() {
        var h = MeasurementHistory(capacity: 5)
        let t0 = Date()
        for i in 0..<8 { h.append(.derived(voltage: Double(i), current: 0, date: t0.addingTimeInterval(Double(i)))) }
        #expect(h.count == 5)
        #expect(h.samples.map(\.voltage) == [3, 4, 5, 6, 7])
        #expect(h.last?.voltage == 7)
    }

    @Test func windowAndDownsamplePreservePeaks() {
        var h = MeasurementHistory()
        let t0 = Date()
        for i in 0..<10_000 {
            let spike = i == 5_000 ? 9.0 : 1.0
            h.append(.derived(voltage: 5, current: spike, date: t0.addingTimeInterval(Double(i) * 0.1)))
        }
        let w = h.window(seconds: nil, maxPoints: 400)
        #expect(w.count <= 520)
        #expect(w.contains { $0.current == 9 })
        let recent = h.window(seconds: 10)
        #expect(recent.count == 101)
    }
}
