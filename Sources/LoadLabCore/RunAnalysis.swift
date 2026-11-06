import Foundation

/// Derived metrics for a recorded discharge. Pure functions of (info, samples).
public struct RunAnalysis: Sendable, Equatable {
    public var capacity_mAh = 0.0
    public var energy_Wh = 0.0
    /// Time under load (current above the floor).
    public var loadedDuration_s = 0.0
    public var averageVoltage: Double?
    public var averageCurrent: Double?
    public var averagePower: Double?
    /// Voltage at half of the delivered capacity: the usual single-number "plateau" figure.
    public var midpointVoltage: Double?
    public var startVoltage: Double?
    public var endLoadedVoltage: Double?
    public var minVoltage: Double?
    /// Open-circuit voltage before the load started, and after it stopped (if recorded).
    public var restVoltageBefore: Double?
    public var restVoltageAfter: Double?
    /// Delivered capacity relative to the entered nominal capacity.
    public var stateOfHealth: Double?
    /// DC resistance estimates from current steps (start, end, pulses).
    public var resistanceSteps: [ResistanceStep] = []

    public struct ResistanceStep: Sendable, Equatable, Identifiable {
        public var id: Double { t }
        public let t: Double
        public let capacity_mAh: Double
        public let deltaCurrent: Double
        public let deltaVoltage: Double
        public var milliohms: Double { abs(deltaVoltage / deltaCurrent) * 1000 }
        public var label: String
    }

    public static let currentFloor = 0.001

    public init() {}

    public static func compute(info: RunInfo, samples: [RunSample]) -> RunAnalysis {
        var a = RunAnalysis()
        guard let last = samples.last else { return a }
        a.capacity_mAh = last.capacity_mAh
        a.energy_Wh = last.energy_Wh
        let loaded = samples.filter { $0.current > currentFloor }
        if let first = loaded.first, let end = loaded.last {
            a.loadedDuration_s = end.t - first.t
            a.startVoltage = first.voltage
            a.endLoadedVoltage = end.voltage
            a.minVoltage = loaded.map(\.voltage).min()
            // Time-weighted averages (sample rates may vary, e.g. across a reconnect gap).
            var tv = 0.0, ti = 0.0, tp = 0.0, tt = 0.0
            for (p, q) in zip(loaded, loaded.dropFirst()) {
                let dt = q.t - p.t
                guard dt > 0 else { continue }
                tv += (p.voltage + q.voltage) / 2 * dt
                ti += (p.current + q.current) / 2 * dt
                tp += (p.power + q.power) / 2 * dt
                tt += dt
            }
            if tt > 0 { a.averageVoltage = tv / tt; a.averageCurrent = ti / tt; a.averagePower = tp / tt }
            else { a.averageVoltage = first.voltage; a.averageCurrent = first.current; a.averagePower = first.power }
            a.midpointVoltage = voltage(atCapacity: a.capacity_mAh / 2, in: loaded)
        }
        if let firstLoadedIndex = samples.firstIndex(where: { $0.current > currentFloor }), firstLoadedIndex > 0 {
            a.restVoltageBefore = samples[firstLoadedIndex - 1].voltage
        }
        if let lastLoadedIndex = samples.lastIndex(where: { $0.current > currentFloor }), lastLoadedIndex < samples.count - 1 {
            a.restVoltageAfter = samples.last?.voltage
        }
        if let nominal = info.cell.nominalCapacity_mAh, nominal > 0 { a.stateOfHealth = a.capacity_mAh / nominal }
        a.resistanceSteps = resistanceSteps(samples)
        return a
    }

    /// Linear interpolation of voltage at a given delivered capacity (samples must be loaded).
    public static func voltage(atCapacity q: Double, in s: [RunSample]) -> Double? {
        guard let i = s.firstIndex(where: { $0.capacity_mAh >= q }) else { return s.last?.voltage }
        guard i > 0 else { return s[0].voltage }
        let a = s[i - 1], b = s[i]
        let span = b.capacity_mAh - a.capacity_mAh
        guard span > 0 else { return b.voltage }
        return a.voltage + (b.voltage - a.voltage) * (q - a.capacity_mAh) / span
    }

    /// Finds abrupt current steps and reports ΔV/ΔI across them. Each estimate covers the
    /// ohmic part plus whatever polarisation happens within one sample period, so it is a
    /// "DC resistance at this sample rate", comparable between runs at the same rate.
    public static func resistanceSteps(_ s: [RunSample], minStep: Double = 0.05) -> [ResistanceStep] {
        guard s.count >= 2 else { return [] }
        let peak = s.map(\.current).max() ?? 0
        let threshold = max(minStep, peak * 0.2)
        var out: [ResistanceStep] = []
        for (p, q) in zip(s, s.dropFirst()) {
            let di = q.current - p.current
            // Skip steps across long gaps (e.g. a reconnect): that ΔV is mostly relaxation.
            guard abs(di) >= threshold, q.t - p.t <= 12 else { continue }
            let label: String
            if p.current <= currentFloor { label = "Load applied" }
            else if q.current <= currentFloor { label = "Load removed" }
            else { label = di > 0 ? "Current step up" : "Current step down" }
            out.append(ResistanceStep(t: q.t, capacity_mAh: q.capacity_mAh, deltaCurrent: di,
                                      deltaVoltage: q.voltage - p.voltage, label: label))
        }
        return out
    }

    /// Incremental capacity dQ/dV (mAh/V) versus voltage. Voltage is resampled on a uniform
    /// capacity grid and smoothed before differentiating; flat stretches are skipped.
    public static func incrementalCapacity(_ samples: [RunSample], points: Int = 160, smoothing: Int = 7) -> [(voltage: Double, dQdV: Double)] {
        let s = samples.filter { $0.current > currentFloor }
        guard s.count > 10, let qMax = s.last?.capacity_mAh, qMax > 0 else { return [] }
        let n = max(points, 20)
        var v = (0...n).map { voltage(atCapacity: qMax * Double($0) / Double(n), in: s) ?? 0 }
        v = movingAverage(v, window: smoothing)
        let dq = qMax / Double(n)
        var out: [(Double, Double)] = []
        for i in 1...n {
            let dv = v[i - 1] - v[i]               // voltage falls during discharge
            guard dv > 1e-5 else { continue }
            out.append(((v[i - 1] + v[i]) / 2, dq / dv))
        }
        return out
    }

    static func movingAverage(_ x: [Double], window: Int) -> [Double] {
        guard window > 1, x.count > window else { return x }
        let h = window / 2
        return x.indices.map { i in
            let lo = max(0, i - h), hi = min(x.count - 1, i + h)
            return x[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }
}
