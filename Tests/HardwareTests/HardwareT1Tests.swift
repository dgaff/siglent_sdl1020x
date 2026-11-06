import Foundation
import Testing
@testable import SDLKit
import SCPIKit

/// T1: live SDL, input OFF, no DUT required. Changes settings, then restores them.
/// Run with:  SDL_HW_HOST=192.168.1.10 swift test --filter HardwareT1
let hwHost = ProcessInfo.processInfo.environment["SDL_HW_HOST"]

@Suite("HardwareT1", .serialized, .enabled(if: hwHost != nil, "set SDL_HW_HOST to run hardware tests"))
struct HardwareT1Tests {

    /// Connects, verifies input is OFF, snapshots, runs `body`, then always restores.
    func withDevice(_ body: (SDL1000X) async throws -> Void) async throws {
        let sdl = SDL1000X(host: hwHost!)
        try await sdl.connection.connect()
        // The SDL accepts one client at a time: always release the connection.
        do {
            try #require(try await sdl.inputOn() == false, "Refusing to run T1 tests with the input ON")
            _ = try await sdl.drainErrors()
            let snap = try await SettingsSnapshot.take(from: sdl)
            var bodyError: Error?
            do { try await body(sdl) } catch { bodyError = error }
            try await sdl.setInput(false)
            try await snap.restore(to: sdl)
            let diff = try await snap.diff(against: sdl)
            #expect(diff.isEmpty, "settings not restored: \(diff.map { "\($0.0.query) \($0.1)→\($0.2)" })")
            let errs = try await sdl.drainErrors()
            #expect(errs.isEmpty, "instrument errors: \(errs)")
            if let bodyError { throw bodyError }
        } catch {
            await sdl.connection.disconnect()
            throw error
        }
        await sdl.connection.disconnect()
    }

    func close(_ a: Double, _ b: Double, tol: Double = 1e-3) -> Bool { abs(a - b) <= tol }

    @Test func staticModesLevelsAndRanges() async throws {
        try await withDevice { sdl in
            for (mode, level) in [(LoadMode.cc, 1.234), (.cv, 12.5), (.cp, 7.75), (.cr, 47.0)] {
                try await sdl.setFunction(mode)
                #expect(try await sdl.function() == mode)
                try await sdl.setCurrentRange(mode, .high)
                try await sdl.setVoltageRange(mode, .high)
                #expect(try await sdl.currentRange(mode) == .high)
                #expect(try await sdl.voltageRange(mode) == .high)
                try await sdl.setLevel(mode, level)
                let got = try await sdl.level(mode)
                #expect(close(got, level), "\(mode) level \(got) != \(level)")
                try await sdl.setCurrentRange(mode, .low)
                #expect(try await sdl.currentRange(mode) == .low)
            }
            try await sdl.setFunction(.led)
            #expect(try await sdl.function() == .led)
            try await sdl.setLedVoltage(2.8); try await sdl.setLedCurrent(0.35); try await sdl.setLedRco(0.3)
            #expect(close(try await sdl.ledVoltage(), 2.8))
            #expect(close(try await sdl.ledCurrent(), 0.35))
            #expect(close(try await sdl.ledRco(), 0.3))

            try await sdl.setFunction(.cr)
            for r in ResistanceRange.allCases {
                try await sdl.setResistanceRange(r)
                #expect(try await sdl.resistanceRange() == r)
            }
            try await sdl.setFunction(.cc)
            try await sdl.setCurrentRange(.cc, .low)
            try await sdl.setSlewRise(0.25); try await sdl.setSlewFall(0.3)
            #expect(close(try await sdl.slewRise(), 0.25))
            try await sdl.setSlewFall(0.75)                  // > 0.5 limit on 5 A: clamped
            #expect(close(try await sdl.slewFall(), 0.5))
            try await sdl.setCurrentRange(.cc, .high)
            try await sdl.setSlewFall(2.0)
            #expect(close(try await sdl.slewFall(), 2.0))
        }
    }

    @Test func transientSettings() async throws {
        try await withDevice { sdl in
            for mode in [LoadMode.cc, .cv, .cp, .cr] {
                try await sdl.setTransientMode(mode, .pulse)
                #expect(try await sdl.transientMode(mode) == .pulse)
                let lo = SDLLimits.transientWidth(mode).lowerBound
                let a = max(0.25, lo) + 0.5, b = max(0.5, lo) + 1
                try await sdl.setTransient(mode, .aWidth, a)
                try await sdl.setTransient(mode, .bWidth, b)
                #expect(close(try await sdl.transient(mode, .aWidth), a))
                #expect(close(try await sdl.transient(mode, .bWidth), b))
            }
            try await sdl.setTransientCurrentRange(.cc, .high)
            try await sdl.setTransient(.cc, .aLevel, 1.5)
            try await sdl.setTransient(.cc, .bLevel, 2.5)
            #expect(close(try await sdl.transient(.cc, .aLevel), 1.5))
            #expect(close(try await sdl.transient(.cc, .bLevel), 2.5))
            try await sdl.setTransientFunction(.cv)
            let tf = try await sdl.transientFunction()
            #expect(LoadMode(reply: tf) == .cv, "FUNC:TRAN? = \(tf)")
        }
    }

    @Test func batterySettingsAndFunctionSwitching() async throws {
        try await withDevice { sdl in
            try await sdl.enterBattery()
            #expect(try await sdl.inBattery())
            let funcInBattery = try await sdl.query(":FUNC?")
            print("OBSERVATION: :FUNC? while in Battery = \(funcInBattery)")
            try await sdl.setBatteryMode(.cp)
            #expect(try await sdl.batteryMode() == .cp)
            try await sdl.setBatteryMode(.cc)
            try await sdl.setBatteryCurrentRange(.low)
            try await sdl.setBatteryVoltageRange(.low)
            try await sdl.setBatteryLevel(0.5)
            try await sdl.setBatteryStopVoltage(3.0)
            try await sdl.setBatteryStopCapacity(2500)
            try await sdl.setBatteryStopTime(7200)
            try await sdl.setBatteryStopVoltageEnabled(true)
            try await sdl.setBatteryStopCapacityEnabled(true)
            try await sdl.setBatteryStopTimeEnabled(false)
            #expect(try await sdl.batteryCurrentRange() == .low)
            #expect(try await sdl.batteryVoltageRange() == .low)
            #expect(close(try await sdl.batteryLevel(), 0.5))
            #expect(close(try await sdl.batteryStopVoltage(), 3.0))
            #expect(close(try await sdl.batteryStopCapacity(), 2500))
            #expect(close(try await sdl.batteryStopTime(), 7200))
            #expect(try await sdl.batteryStopVoltageEnabled())
            #expect(try await sdl.batteryStopCapacityEnabled())
            #expect(try await sdl.batteryStopTimeEnabled() == false)
            for p in SDL1000X.DCRParam.allCases {
                try await sdl.setDCR(p, p == .current2 ? 1.0 : 0.5)
            }
            #expect(close(try await sdl.dcr(.current2), 1.0))
            print("OBSERVATION: DCR TIME1 after set 0.5 = \(try await sdl.dcr(.time1))")
            print("OBSERVATION: DISCHA:CAP=\(try await sdl.batteryDischargedCapacity()) DISCHA:TIM=\(try await sdl.batteryDischargeTime())")

            // Does selecting a static function leave Battery?
            try await sdl.setFunction(.cc)
            let still = try await sdl.inBattery()
            print("OBSERVATION: inBattery after :FUNC CURR = \(still)")
            #expect(still == false)
        }
    }

    @Test func listSettings() async throws {
        try await withDevice { sdl in
            let steps = [ListStep(level: 0.5, width: 1, slew: 0.1),
                         ListStep(level: 1.0, width: 2.5, slew: 0.2),
                         ListStep(level: 0.25, width: 0.5, slew: 0.3)]
            try await sdl.setListMode(.cc)
            try await sdl.setListCurrentRange(.low)
            try await sdl.setListStepCount(steps.count)
            try await sdl.setListCount(3)
            try await sdl.enterList()           // step edits are ignored outside List mode
            for (i, s) in steps.enumerated() { try await sdl.setListStep(i + 1, s) }
            #expect(try await sdl.listStepCount() == 3)
            #expect(try await sdl.listCount() == 3)
            for (i, s) in steps.enumerated() {
                let got = try await sdl.listStep(i + 1)
                #expect(close(got.level, s.level) && close(got.width, s.width) && close(got.slew, s.slew),
                        "step \(i + 1): \(got) != \(s)")
            }
            #expect(try await sdl.inList())
            print("OBSERVATION: in List: TEST:STEP?=\(try await sdl.testStep()) TEST:STOP?=\(try await sdl.testStopped())")
            try await sdl.setFunction(.cc)
            #expect(try await sdl.inList() == false)
        }
    }

    @Test func programSettings() async throws {
        try await withDevice { sdl in
            var a = ProgramStep(); a.mode = .cc; a.level = 0.5; a.timeOn = 2; a.timeOff = 1; a.min = 1; a.max = 20
            a.currentRange = .low; a.voltageRange = .high
            var b = ProgramStep(); b.mode = .cr; b.level = 100; b.resistanceRange = .middle; b.pause = true; b.timeDelay = 0.5
            b.min = 2; b.max = 30
            try await sdl.enterProgram()        // step edits are ignored outside Program mode
            try await sdl.setProgramStepCount(2)
            try await sdl.setProgramStep(1, a)
            try await sdl.setProgramStep(2, b)
            #expect(try await sdl.programStepCount() == 2)
            let ga = try await sdl.programStep(1), gb = try await sdl.programStep(2)
            #expect(ga.mode == .cc && close(ga.level, 0.5) && close(ga.timeOn, 2) && ga.currentRange == .low)
            #expect(gb.mode == .cr && close(gb.level, 100) && gb.pause && gb.resistanceRange == .middle)
            #expect(try await sdl.inProgram())
            print("OBSERVATION: PROG:TEST? 1 = \(try await sdl.programResult(1))")
            try await sdl.setFunction(.cc)
            #expect(try await sdl.inProgram() == false)
        }
    }

    @Test func ocptOpptSettings() async throws {
        try await withDevice { sdl in
            for t in SDL1000X.ProtectionTest.allCases {
                try await sdl.setProtectionTestCurrentRange(t, .low)
                try await sdl.setProtectionTestVoltageRange(t, .low)
                let vals: [(SDL1000X.ProtectionParam, Double)] = [(.voltage, 2.5), (.start, 0.2), (.step, 0.1),
                    (.stepDelay, 0.5), (.end, 3), (.min, 0.5), (.max, 4)]
                for (p, v) in vals { try await sdl.setProtectionTest(t, p, v) }
                for (p, v) in vals {
                    let got = try await sdl.protectionTest(t, p)
                    #expect(close(got, v), "\(t.label) \(p) \(got) != \(v)")
                }
                try await sdl.enterProtectionTest(t)
                #expect(try await sdl.inProtectionTest(t))
                try await sdl.setFunction(.cc)
                #expect(try await sdl.inProtectionTest(t) == false)
            }
        }
    }

    @Test func utilityAndSystemSettings() async throws {
        try await withDevice { sdl in
            try await sdl.setVOn(1.5); #expect(close(try await sdl.vOn(), 1.5))
            let latch = try await sdl.vOnLatch()
            try await sdl.setVOnLatch(!latch); #expect(try await sdl.vOnLatch() == !latch)
            for p in [SDL1000X.Protection.current, .power] {
                try await sdl.setProtectionLevel(p, p == .current ? 4.5 : 50)
                try await sdl.setProtectionDelay(p, 1.5)
                try await sdl.setProtectionEnabled(p, true)
                #expect(close(try await sdl.protectionLevel(p), p == .current ? 4.5 : 50))
                #expect(close(try await sdl.protectionDelay(p), 1.5))
                #expect(try await sdl.protectionEnabled(p))
            }
            try await sdl.setAverageExponent(11); #expect(try await sdl.averageExponent() == 11)
            try await sdl.setTriggerSource(.bus); #expect(try await sdl.triggerSource() == .bus)
            try await sdl.setStopOnFail(true); #expect(try await sdl.stopOnFail())
            try await sdl.setCurrentMonitor(true); #expect(try await sdl.currentMonitor())
            try await sdl.setVoltageMonitor(true); #expect(try await sdl.voltageMonitor())
            try await sdl.setTimeTestLow(2); try await sdl.setTimeTestHigh(9)
            #expect(close(try await sdl.timeTestLow(), 2))
            #expect(close(try await sdl.timeTestHigh(), 9))
            try await sdl.setExternalCurrentRange(.low)
            #expect(try await sdl.externalCurrentRange() == .low)
            // Sense is left alone: toggling it with nothing wired is harmless but pointless.
        }
    }
}
