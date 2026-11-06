import Foundation
import Testing
@testable import SDLKit
import SCPIKit
import SDLSimulator

@Suite(.serialized) struct SDLKitSimTests {
    func withSDL(_ body: (SDLSimulator, SDL1000X) async throws -> Void) async throws {
        let sim = SDLSimulator()
        let port = try await sim.start()
        let sdl = SDL1000X(host: "127.0.0.1", port: port)
        try await sdl.connection.connect()
        try await body(sim, sdl)
        await sdl.connection.disconnect()
        sim.stop()
    }

    @Test func formatting() {
        #expect(fmt(5) == "5")
        #expect(fmt(0.5) == "0.5")
        #expect(fmt(1.23456789) == "1.234568")
        #expect(fmt(-2.25) == "-2.25")
    }

    @Test func modeParsing() {
        #expect(LoadMode(reply: "CURRENT") == .cc)
        #expect(LoadMode(reply: "RESISTANCE") == .cr)
        #expect(BatteryMode(reply: "POWER") == .cp)
        #expect(BatteryMode(reply: "VOLTAGE") == nil)
        #expect(CurrentRange(reply: 30) == .high)
        #expect(VoltageRange(reply: 36) == .low)
        #expect(TransientMode(reply: "CONTINUOUS") == .continuous)
    }

    @Test func staticCCSinksCurrent() async throws {
        try await withSDL { sim, sdl in
            sim.sourceVoltage = 12; sim.sourceResistance = 0.1
            try await sdl.setFunction(.cc)
            try await sdl.setCurrentRange(.cc, .high)
            try await sdl.setLevel(.cc, 2)
            #expect(try await sdl.level(.cc) == 2)
            try await sdl.setInput(true)
            let m = try await sdl.measureAll()
            #expect(abs(m.current - 2) < 1e-6)
            #expect(abs(m.voltage - 11.8) < 1e-6)
            #expect(abs(m.power - 23.6) < 1e-6)
            try await sdl.setInput(false)
            #expect(try await sdl.measureCurrent() == 0)
        }
    }

    @Test func rangesRoundTrip() async throws {
        try await withSDL { _, sdl in
            try await sdl.setCurrentRange(.cc, .high)
            try await sdl.setVoltageRange(.cc, .low)
            #expect(try await sdl.currentRange(.cc) == .high)
            #expect(try await sdl.voltageRange(.cc) == .low)
            try await sdl.setResistanceRange(.upper)
            #expect(try await sdl.resistanceRange() == .upper)
        }
    }

    @Test func batteryStopsAtCapacity() async throws {
        try await withSDL { sim, sdl in
            sim.sourceVoltage = 4; sim.sourceResistance = 0.05
            try await sdl.enterBattery()
            #expect(try await sdl.inBattery())
            try await sdl.setBatteryMode(.cc)
            try await sdl.setBatteryCurrentRange(.high)
            try await sdl.setBatteryLevel(30)            // 30 A → 8.33 mAh/s
            try await sdl.setBatteryStopCapacity(5)
            try await sdl.setBatteryStopCapacityEnabled(true)
            try await sdl.setInput(true)
            try await Task.sleep(for: .milliseconds(900))
            #expect(try await sdl.inputOn() == false)
            #expect(try await sdl.batteryDischargedCapacity() >= 5)
        }
    }

    @Test func listStepsRoundTrip() async throws {
        try await withSDL { _, sdl in
            try await sdl.setListStepCount(2)
            // Ignored outside List mode (real-device behaviour):
            try await sdl.setListStep(1, ListStep(level: 9, width: 9, slew: 0.1))
            #expect(try await sdl.listStep(1).level == 2)
            try await sdl.enterList()
            try await sdl.setListStep(1, ListStep(level: 1.5, width: 2, slew: 0.1))
            try await sdl.setListStep(2, ListStep(level: 3, width: 0.5, slew: 0.2))
            let s2 = try await sdl.listStep(2)
            #expect(s2.level == 3 && s2.width == 0.5 && s2.slew == 0.2)
            #expect(try await sdl.listStepCount() == 2)
        }
    }

    @Test func outOfRangeWritesAreClampedOrIgnored() async throws {
        try await withSDL { _, sdl in
            try await sdl.setCurrentRange(.cc, .low)
            try await sdl.setSlewFall(0.75)                   // > 0.5 limit on 5 A range
            #expect(try await sdl.slewFall() == 0.5)
            try await sdl.setCurrentRange(.cc, .high)
            try await sdl.setSlewFall(0.75)
            #expect(try await sdl.slewFall() == 0.75)
            try await sdl.setTransient(.cv, .aWidth, 0.25)    // CV minimum is 1 s
            #expect(try await sdl.transient(.cv, .aWidth) == 1)
            try await sdl.setLevel(.cr, 5)
            try await sdl.setLevel(.cr, 0.001)                // below CR minimum: ignored
            #expect(try await sdl.level(.cr) == 5)
        }
    }

    @Test func snapshotRestoresStepTables() async throws {
        try await withSDL { _, sdl in
            let snap = try await SettingsSnapshot.take(from: sdl)
            #expect(snap.listSteps?.count == SettingsSnapshot.capturedSteps)
            try await sdl.enterList()
            try await sdl.setListStep(2, ListStep(level: 0.7, width: 3, slew: 0.2))
            try await sdl.enterProgram()
            var p = ProgramStep(); p.mode = .cr; p.level = 50; p.pause = true
            try await sdl.setProgramStep(3, p)
            try await sdl.setFunction(.cc)
            #expect(try await snap.diff(against: sdl).count == 2)
            try await snap.restore(to: sdl)
            #expect(try await snap.diff(against: sdl).isEmpty)
            let inList = try await sdl.inList(), inProgram = try await sdl.inProgram()
            #expect(!inList && !inProgram)
        }
    }

    @Test func snapshotRestoreRoundTrip() async throws {
        try await withSDL { _, sdl in
            try await sdl.setLevel(.cc, 1.25)
            try await sdl.setAverageExponent(12)
            let snap = try await SettingsSnapshot.take(from: sdl)
            #expect(snap.values.count > 80)
            try await sdl.setLevel(.cc, 3)
            try await sdl.setAverageExponent(7)
            try await sdl.enterBattery()
            #expect(try await snap.diff(against: sdl).count == 2)
            try await snap.restore(to: sdl)
            #expect(try await snap.diff(against: sdl).isEmpty)
            #expect(try await sdl.inBattery() == false)
            #expect(try await sdl.drainErrors().isEmpty)
        }
    }

    @Test func everyDocumentedQueryAnswersOnSim() async throws {
        try await withSDL { _, sdl in
            for q in SettingsSnapshot.entries.map(\.query) + SettingsSnapshot.readOnlyQueries {
                let r = try? await sdl.query(q)
                #expect(r != nil, "no reply to \(q)")
            }
        }
    }
}
