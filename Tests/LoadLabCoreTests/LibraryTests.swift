import Foundation
import Testing
@testable import LoadLabCore
import SDLKit

/// Generates realistic-looking recorded runs without hardware.
@MainActor
enum SyntheticRuns {
    /// Li-ion-like open-circuit voltage vs state of charge (1 = full).
    static func ocv(_ soc: Double) -> Double {
        let x = min(max(soc, 0), 1)
        // 4.20 V full, ~3.75 V at half, steep knee near empty (2.6 V at 0 %).
        return 3.45 + 0.6 * x + 0.15 * pow(x, 8) - 0.35 * exp(-20 * x) - 0.5 * exp(-60 * x)
    }

    /// Discharges a cell of `capacity` mAh at `current` A with internal resistance `r` Ω,
    /// one sample per `dt` s, until the loaded voltage reaches `cutoff`.
    @discardableResult
    static func make(store: RunStore, title: String, capacity: Double, current: Double, r: Double,
                     cutoff: Double = 3.0, dt: Double = 2, nominal: Double? = nil,
                     startedDaysAgo: Double = 0) throws -> RunRecorder {
        // Estimate the duration so the run "ends now".
        let duration = capacity / (current * 1000) * 3600
        let start = Date().addingTimeInterval(-duration - 10 - startedDaysAgo * 86400)
        var cell = CellInfo(); cell.name = title; cell.nominalCapacity_mAh = nominal ?? capacity
        var cfg = BatteryConfig(); cfg.mode = .cc; cfg.level = current
        cfg.stopVoltageEnabled = true; cfg.stopVoltage = cutoff
        var opts = RecordingOptions(); opts.sampleRateHz = 1 / dt
        let info = RunInfo(title: title, cell: cell, battery: cfg, options: opts, startedAt: start)
        let rec = try RunRecorder(info: info, store: store)
        var t = 0.0, q = 0.0
        func reading(_ v: Double, _ i: Double) -> Reading {
            Reading.derived(voltage: v, current: i, date: start.addingTimeInterval(t))
        }
        rec.ingest(reading(ocv(1), 0))                       // rest before
        t += dt
        while true {
            let v = ocv(1 - q / capacity) - current * r
            rec.ingest(reading(v, current))
            if v <= cutoff || q > capacity * 1.05 { break }
            q += current * dt / 3.6
            t += dt
        }
        t += dt
        rec.ingest(reading(ocv(1 - q / capacity), 0))        // rest after
        rec.updateDeviceCounters(capacity: q.rounded(.down), time: t.rounded(.down))
        rec.finish(status: .completed, reason: .voltageCutoff)
        return rec
    }
}

@MainActor @Suite struct AnalysisTests {
    func store() -> RunStore {
        RunStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("loadlab-lib-\(UUID().uuidString)"))
    }

    @Test func metricsFromSyntheticCell() throws {
        let s = store()
        let rec = try SyntheticRuns.make(store: s, title: "Synthetic 3000", capacity: 3000, current: 1.5, r: 0.050,
                                         dt: 5, nominal: 3200)
        let a = RunAnalysis.compute(info: rec.info, samples: rec.samples)
        #expect(a.capacity_mAh > 2500 && a.capacity_mAh < 3010, "capacity \(a.capacity_mAh)")
        #expect(abs((a.stateOfHealth ?? 0) - a.capacity_mAh / 3200) < 1e-9)
        #expect(abs((a.averageCurrent ?? 0) - 1.5) < 1e-6)
        #expect((a.midpointVoltage ?? 0) > 3.5 && (a.midpointVoltage ?? 0) < 3.9)
        #expect(a.restVoltageBefore != nil && a.restVoltageAfter != nil)
        // DC resistance from the load-applied / load-removed steps ≈ 50 mΩ.
        let applied = try #require(a.resistanceSteps.first { $0.label == "Load applied" })
        #expect(abs(applied.milliohms - 50) < 2.5, "applied \(applied.milliohms) mΩ")
        let removed = try #require(a.resistanceSteps.first { $0.label == "Load removed" })
        #expect(abs(removed.milliohms - 50) < 10, "removed \(removed.milliohms) mΩ")
        // Energy ≈ capacity × average voltage.
        #expect(abs(a.energy_Wh - a.capacity_mAh / 1000 * (a.averageVoltage ?? 0)) / a.energy_Wh < 0.01)
    }

    @Test func incrementalCapacityIsPositiveAndSpansVoltage() throws {
        let rec = try SyntheticRuns.make(store: store(), title: "dQdV", capacity: 2000, current: 1, r: 0.04, dt: 5)
        let ic = RunAnalysis.incrementalCapacity(rec.samples)
        #expect(ic.count > 50)
        #expect(ic.allSatisfy { $0.dQdV > 0 })
        let vs = ic.map(\.voltage)
        #expect((vs.max() ?? 0) - (vs.min() ?? 0) > 0.6)
    }

    @Test func midpointInterpolation() {
        let t0 = Date()
        let s = (0...10).map { k in
            RunSample(t: Double(k), date: t0, voltage: 4.0 - 0.1 * Double(k), current: 1, power: 4, resistance: 4,
                      capacity_mAh: Double(k) * 10, energy_Wh: 0)
        }
        #expect(abs((RunAnalysis.voltage(atCapacity: 45, in: s) ?? 0) - 3.55) < 1e-9)
    }

    @Test func libraryListsEditsAndTrashes() async throws {
        let s = store()
        try SyntheticRuns.make(store: s, title: "Old cell", capacity: 200, current: 1, r: 0.1, dt: 5, startedDaysAgo: 3)
        try SyntheticRuns.make(store: s, title: "New cell", capacity: 250, current: 1, r: 0.08, dt: 5)
        let lib = LibraryModel(store: s)
        await lib.reload()
        #expect(lib.entries.map(\.title) == ["New cell", "Old cell"])     // newest first
        let e = lib.entries[1]
        var cell = e.info.cell; cell.notes = "after 300 cycles"; cell.temperatureC = 22
        try lib.update(e, title: "Old cell (aged)", cell: cell)
        let reloaded = LibraryModel(store: s)
        await reloaded.reload()
        let edited = try #require(reloaded.entries.first { $0.id == e.id })
        #expect(edited.title == "Old cell (aged)" && edited.info.cell.notes == "after 300 cycles")
        let samples = await reloaded.samples(for: edited)
        #expect(samples.count > 20)
        try reloaded.moveToTrash(edited)
        #expect(reloaded.entries.count == 1)
        await reloaded.reload()
        #expect(reloaded.entries.count == 1)
    }

    /// Writes fixture runs for UI screenshots when LOADLAB_FIXTURES_DIR is set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LOADLAB_FIXTURES_DIR"] != nil))
    func writeFixtures() throws {
        let s = RunStore(root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOADLAB_FIXTURES_DIR"]!))
        try SyntheticRuns.make(store: s, title: "Samsung 30Q #1", capacity: 2950, current: 1.5, r: 0.022, dt: 10, nominal: 3000, startedDaysAgo: 20)
        try SyntheticRuns.make(store: s, title: "Samsung 30Q #2", capacity: 2870, current: 1.5, r: 0.026, dt: 10, nominal: 3000, startedDaysAgo: 12)
        try SyntheticRuns.make(store: s, title: "Samsung 30Q #2 (aged)", capacity: 2410, current: 1.5, r: 0.048, dt: 10, nominal: 3000, startedDaysAgo: 2)
        try SyntheticRuns.make(store: s, title: "Generic 18650", capacity: 1850, current: 1.0, r: 0.090, dt: 10, nominal: 2200, startedDaysAgo: 1)
    }
}
