import Foundation
import Testing
@testable import LoadLabCore
@testable import SDLKit
import SCPIKit

/// Exploratory probes of List / Program / OCPT / OPPT run behaviour (Phase 6). They print a
/// time series instead of asserting. The supply's current limit caps every probe below 1 A.
///
/// Run with:  SDL_PROBE=1 SDL_HW_HOST=192.168.1.10 PSU_HW_HOST=192.168.1.85 swift test --filter HardwareProbe
@MainActor
@Suite("HardwareProbe", .serialized,
       .enabled(if: hwHost != nil && psuHost != nil && ProcessInfo.processInfo.environment["SDL_PROBE"] != nil))
struct HardwareProbeTests {
    let rig = HardwareT2Tests()

    func sample(_ s: DeviceSession, _ psu: BenchSupply, seconds: Double, label: String, extra: [String] = []) async {
        let t0 = ContinuousClock.now
        while ContinuousClock.now - t0 < .milliseconds(Int(seconds * 1000)) {
            let t = Double((ContinuousClock.now - t0).components.attoseconds) / 1e18 + Double((ContinuousClock.now - t0).components.seconds)
            var parts = [String(format: "%@ %5.2fs", label, t)]
            for q in [":INP?", ":TEST:STEP?", ":TEST:STOP?", "MEAS:VOLT?", "MEAS:CURR?"] + extra {
                let r = (try? await s.sdl.connection.query(q, timeout: .seconds(1))) ?? "—"
                parts.append("\(q)=\(r)")
            }
            parts.append(String(format: "PSU=%.4fA", (try? await psu.current()) ?? .nan))
            print("PROBE", parts.joined(separator: " "))
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    @Test func listRun() async throws {
        try await rig.withRig(volts: 5, amps: 0.8) { s, psu in
            let sdl = s.sdl
            try await sdl.enterList()
            try await sdl.setListMode(.cc)
            try await sdl.setListCurrentRange(.low)
            try await sdl.setListVoltageRange(.low)
            try await sdl.setListStepCount(3)
            try await sdl.setListCount(2)
            try await sdl.setListStep(1, ListStep(level: 0.1, width: 1, slew: 0.5))
            try await sdl.setListStep(2, ListStep(level: 0.3, width: 1, slew: 0.5))
            try await sdl.setListStep(3, ListStep(level: 0.5, width: 1, slew: 0.5))
            print("PROBE trigger source before:", try await sdl.query("TRIG:SOUR?"))
            try await sdl.setTriggerSource(.bus)
            try await sdl.setInput(true)
            await sample(s, psu, seconds: 3, label: "list-on")
            try await sdl.trigger()
            await sample(s, psu, seconds: 9, label: "list-trg")
            try await sdl.trigger()
            await sample(s, psu, seconds: 3, label: "list-trg2")
            try await sdl.setInput(false)
            await sample(s, psu, seconds: 1, label: "list-off")
            try await sdl.setInput(true)
            await sample(s, psu, seconds: 3, label: "list-on2")
            try await sdl.setInput(false)
        }
    }

    @Test func listManualTriggerAndExt() async throws {
        try await rig.withRig(volts: 5, amps: 0.8) { s, psu in
            let sdl = s.sdl
            try await sdl.enterList()
            try await sdl.setListMode(.cc)
            try await sdl.setListCurrentRange(.low)
            try await sdl.setListStepCount(2)
            try await sdl.setListCount(1)
            try await sdl.setListStep(1, ListStep(level: 0.2, width: 1, slew: 0.5))
            try await sdl.setListStep(2, ListStep(level: 0.1, width: 1, slew: 0.5))
            try await sdl.setTriggerSource(.manual)
            try await sdl.setInput(true)
            await sample(s, psu, seconds: 1, label: "listM-on")
            try await sdl.trigger()
            await sample(s, psu, seconds: 3.5, label: "listM-trg")
            try await sdl.setInput(false)
            print("PROBE MEAS:EXT?", (try? await sdl.connection.query("MEAS:EXT?", timeout: .seconds(2))) ?? "(no reply)")
        }
    }

    /// OCPT whose end level is below the supply's limit: never trips.
    @Test func ocptNoTrip() async throws {
        try await rig.withRig(volts: 5, amps: 0.5) { s, psu in
            let sdl = s.sdl
            try await sdl.enterProtectionTest(.ocp)
            try await sdl.setProtectionTestCurrentRange(.ocp, .low)
            for (p, v) in [(SDL1000X.ProtectionParam.start, 0.1), (.step, 0.1), (.stepDelay, 0.3), (.end, 0.3),
                           (.min, 0.4), (.max, 0.6), (.voltage, 3.0)] {
                try await sdl.setProtectionTest(.ocp, p, v)
            }
            try await sdl.setInput(true)
            await sample(s, psu, seconds: 5, label: "ocpN-on")
            try await sdl.setInput(false)
        }
    }

    @Test func programRun() async throws {
        try await rig.withRig(volts: 5, amps: 0.8) { s, psu in
            let sdl = s.sdl
            try await sdl.enterProgram()
            try await sdl.setProgramStepCount(2)
            var a = ProgramStep()
            a.mode = .cc; a.currentRange = .low; a.voltageRange = .low; a.level = 0.2
            a.timeOn = 1; a.timeOff = 1; a.timeDelay = 0.5; a.min = 4.5; a.max = 5.5
            var b = a
            b.level = 0.4; b.min = 4.9; b.max = 4.95
            try await sdl.setProgramStep(1, a)
            try await sdl.setProgramStep(2, b)
            try await sdl.setTriggerSource(.bus)
            try await sdl.setInput(true)
            await sample(s, psu, seconds: 3, label: "prog-on", extra: [":PROG:TEST? 1", ":PROG:TEST? 2"])
            try await sdl.trigger()
            await sample(s, psu, seconds: 8, label: "prog-trg", extra: [":PROG:TEST? 1", ":PROG:TEST? 2"])
            try await sdl.setInput(false)
            await sample(s, psu, seconds: 1, label: "prog-off", extra: [":PROG:TEST? 1", ":PROG:TEST? 2"])
        }
    }

    /// When does :PROG:TEST? answer after a run ends (CC + CV steps)?
    @Test func programResultTiming() async throws {
        try await rig.withRig(volts: 5, amps: 0.5) { s, psu in
            let sdl = s.sdl
            try await sdl.enterProgram()
            try await sdl.setProgramStepCount(3)
            var a = ProgramStep()
            a.mode = .cc; a.currentRange = .low; a.voltageRange = .low; a.level = 0.2
            a.timeOn = 1; a.timeOff = 0.5; a.timeDelay = 0.5; a.min = 4.5; a.max = 5.5
            var b = a; b.level = 0.4; b.min = 4.0; b.max = 4.5
            var cv = a; cv.mode = .cv; cv.level = 4.0; cv.min = 0.45; cv.max = 0.55
            for (i, st) in [a, b, cv].enumerated() { try await sdl.setProgramStep(i + 1, st, full: true) }
            try await sdl.setTriggerSource(.bus)
            try await sdl.setInput(true)
            try await sdl.trigger()
            let t0 = ContinuousClock.now
            func el() -> String { String(format: "%.2f", Double((ContinuousClock.now - t0).components.seconds) + Double((ContinuousClock.now - t0).components.attoseconds) / 1e18) }
            while (try await sdl.inputOn()) { try await Task.sleep(for: .milliseconds(100)) }
            print("PROBE input off at", el())
            for round in 0..<4 {
                for n in 1...3 {
                    let r = (try? await sdl.connection.query(":PROG:TEST? \(n)", timeout: .seconds(3))) ?? "(no reply)"
                    print("PROBE round \(round) t=\(el()) :PROG:TEST? \(n) ->", r)
                }
                try await Task.sleep(for: .seconds(1))
            }
            print("PROBE STOP:ON:FAIL?", try await sdl.query("STOP:ON:FAIL?"), "step", try await sdl.testStep())
        }
    }

    /// The supply's 0.5 A limit plays the device under test's over-current protection.
    @Test func ocptRun() async throws {
        try await rig.withRig(volts: 5, amps: 0.5) { s, psu in
            let sdl = s.sdl
            try await sdl.enterProtectionTest(.ocp)
            try await sdl.setProtectionTestCurrentRange(.ocp, .low)
            try await sdl.setProtectionTestVoltageRange(.ocp, .low)
            for (p, v) in [(SDL1000X.ProtectionParam.start, 0.1), (.step, 0.05), (.stepDelay, 0.3), (.end, 0.8),
                           (.min, 0.4), (.max, 0.6), (.voltage, 3.0)] {
                try await sdl.setProtectionTest(.ocp, p, v)
                print("PROBE OCP \(p.rawValue) =", try await sdl.protectionTest(.ocp, p))
            }
            try await sdl.setTriggerSource(.bus)
            try await sdl.setInput(true)
            await sample(s, psu, seconds: 2, label: "ocp-on")
            try await sdl.trigger()
            await sample(s, psu, seconds: 8, label: "ocp-trg")
            try await sdl.setInput(false)
        }
    }

    @Test func opptRun() async throws {
        try await rig.withRig(volts: 5, amps: 0.5) { s, psu in
            let sdl = s.sdl
            try await sdl.enterProtectionTest(.opp)
            try await sdl.setProtectionTestCurrentRange(.opp, .low)
            try await sdl.setProtectionTestVoltageRange(.opp, .low)
            for (p, v) in [(SDL1000X.ProtectionParam.start, 0.5), (.step, 0.25), (.stepDelay, 0.3), (.end, 3.5),
                           (.min, 2.0), (.max, 3.0), (.voltage, 3.0)] {
                try await sdl.setProtectionTest(.opp, p, v)
                print("PROBE OPP \(p.rawValue) =", try await sdl.protectionTest(.opp, p))
            }
            try await sdl.setTriggerSource(.bus)
            try await sdl.setInput(true)
            await sample(s, psu, seconds: 2, label: "opp-on")
            try await sdl.trigger()
            await sample(s, psu, seconds: 8, label: "opp-trg")
            try await sdl.setInput(false)
        }
    }
}

/// Connect after errors were left queued by another client (set up by a script first).
@MainActor
@Suite("HardwareProbeConnect", .enabled(if: hwHost != nil && ProcessInfo.processInfo.environment["SDL_PROBE"] != nil))
struct HardwareProbeConnect {
    @Test func connectWithQueuedErrors() async throws {
        let s = DeviceSession(host: hwHost!)
        await s.connect()
        print("PROBE link:", s.link)
        for e in s.log.prefix(30) { print("PROBE LOG", e.kind, e.text) }
        await s.disconnect()
    }
}
