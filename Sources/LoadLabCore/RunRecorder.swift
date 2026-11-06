import Foundation
import Observation
import SDLKit

/// Records one run: integrates capacity/energy from live readings, streams samples to CSV,
/// keeps them in memory for charts, and maintains run.json (events, summary, status).
@MainActor @Observable
public final class RunRecorder {
    public private(set) var info: RunInfo
    public let folder: URL
    public private(set) var samples: [RunSample] = []
    public private(set) var integrator = Integrator()
    /// Latest device counters (1 mAh / 1 s resolution).
    public private(set) var deviceCapacity: Double?
    public private(set) var deviceTime: Double?
    public var isActive: Bool { info.status == .running }

    private let store: RunStore
    private var writer: CSVWriter?
    /// Wall-clock start; elapsed time is measured from here (survives app restarts).
    private var origin: Date { info.startedAt }
    private var lastSampleDate: Date?
    private var lastSave = Date.distantPast

    /// Starts a new run folder.
    public init(info: RunInfo, store: RunStore) throws {
        self.info = info
        self.store = store
        folder = try store.createFolder(for: info)
        writer = try CSVWriter(url: folder.appendingPathComponent("samples.csv"))
        addEvent("start", "Run started")
        try store.save(self.info, in: folder)
    }

    /// Re-opens a run that was still running when the app quit, restoring totals from the CSV.
    public init(resuming folder: URL, store: RunStore) throws {
        self.store = store
        self.folder = folder
        info = try store.load(folder)
        samples = store.loadSamples(folder)
        if let last = samples.last {
            // Continue the totals and bridge the time the app was away (trapezoid from the
            // last recorded point); the device counter remains the cross-check.
            integrator = Integrator(capacity_mAh: last.capacity_mAh, energy_Wh: last.energy_Wh)
            integrator.seed(date: last.date, current: last.current, power: last.power)
            lastSampleDate = last.date
        }
        writer = try CSVWriter(url: folder.appendingPathComponent("samples.csv"))
        addEvent("resume", "Recording resumed after LoadLab restarted")
        try store.save(info, in: folder)
    }

    /// Adds one reading. Gaps (> 5 × the sample period, e.g. a network drop) are logged; the
    /// integration bridges them with the average current, and the device counter is the
    /// cross-check for what happened meanwhile.
    public func ingest(_ r: Reading) {
        guard isActive else { return }
        if let last = lastSampleDate {
            let gap = r.date.timeIntervalSince(last)
            if gap > max(5 / info.options.sampleRateHz, 3) {
                addEvent("gap", String(format: "No samples for %.1f s", gap))
            }
            if gap <= 0 { return }
        }
        integrator.add(date: r.date, current: r.current, power: r.power)
        let s = RunSample(t: r.date.timeIntervalSince(origin), date: r.date, voltage: r.voltage, current: r.current,
                          power: r.power, resistance: r.resistance,
                          capacity_mAh: integrator.capacity_mAh, energy_Wh: integrator.energy_Wh)
        samples.append(s)
        lastSampleDate = r.date
        writer?.append(s, deviceCapacity: deviceCapacity, deviceTime: deviceTime)
        if Date().timeIntervalSince(lastSave) > 30 { updateSummary(); save() }
    }

    public func updateDeviceCounters(capacity: Double, time: Double) {
        deviceCapacity = capacity
        deviceTime = time
    }

    public func addEvent(_ kind: String, _ text: String) {
        let now = Date()
        info.events.append(RunEvent(t: now.timeIntervalSince(info.startedAt), date: now, kind: kind, text: text))
    }

    /// Ends the run (idempotent).
    public func finish(status: RunStatus, reason: EndReason) {
        guard isActive else { return }
        info.status = status
        info.endReason = reason
        info.endedAt = Date()
        addEvent("stop", reason.label)
        updateSummary()
        writer?.close()
        writer = nil
        save()
    }

    public func setNotes(_ notes: String) { info.cell.notes = notes; save() }

    private func updateSummary() {
        var s = RunSummary()
        s.samples = samples.count
        // From the recorded data (the last sample), not the wall clock at finish.
        s.duration_s = (samples.last?.date ?? info.endedAt ?? Date()).timeIntervalSince(info.startedAt)
        s.capacity_mAh = integrator.capacity_mAh
        s.energy_Wh = integrator.energy_Wh
        s.deviceCapacity_mAh = deviceCapacity
        s.deviceTime_s = deviceTime
        // Statistics over samples where current flowed (excludes the tail after cut-off).
        let loaded = samples.filter { $0.current > 0.001 }
        s.startVoltage = loaded.first?.voltage
        s.endVoltage = loaded.last?.voltage
        s.minVoltage = loaded.map(\.voltage).min()
        if !loaded.isEmpty {
            s.averageVoltage = loaded.map(\.voltage).reduce(0, +) / Double(loaded.count)
            s.averageCurrent = loaded.map(\.current).reduce(0, +) / Double(loaded.count)
        }
        info.summary = s
    }

    private func save() {
        lastSave = Date()
        writer?.flush()
        try? store.save(info, in: folder)
    }

    /// Voltage of the last sample taken under load (the cell relaxes upward once the load
    /// stops, so the very last reading can sit above the cut-off).
    public var lastLoadedVoltage: Double? { samples.last { $0.current > 0.001 }?.voltage }

    /// Infers why the instrument ended the test (it doesn't say).
    /// - Parameters:
    ///   - lastVoltage: last voltage measured under load.
    ///   - restingVoltage: voltage after the load stopped (if known).
    nonisolated public static func inferEndReason(config: BatteryConfig, lastVoltage: Double?, deviceCapacity: Double?,
                                      deviceTime: Double?, restingVoltage: Double? = nil) -> EndReason {
        // Cells collapse quickly at the knee, so the last sampled loaded voltage can sit well
        // above V_Stop. Accept it as a voltage cut-off if it was within 10 % of V_Stop, or if
        // even the relaxed (unloaded) voltage is at or below V_Stop.
        if config.stopVoltageEnabled {
            if let v = lastVoltage, v <= config.stopVoltage * 1.10 + 0.02 { return .voltageCutoff }
            if let r = restingVoltage, r <= config.stopVoltage { return .voltageCutoff }
        }
        if config.stopCapacityEnabled, let c = deviceCapacity, c >= config.stopCapacity - 1 { return .capacityLimit }
        if config.stopTimeEnabled, let t = deviceTime, t >= config.stopTime - 2 { return .timeLimit }
        return .inputSwitchedOff
    }
}
