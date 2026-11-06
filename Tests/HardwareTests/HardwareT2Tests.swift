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
        // Teardown always runs, in safety order.
        try? await s.sdl.setInput(false)
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
}
