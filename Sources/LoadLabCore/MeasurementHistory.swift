import Foundation
import SDLKit

/// One plotted sample. `t` is seconds since the history's origin.
public struct Sample: Sendable, Equatable, Identifiable {
    public var id: Double { t }
    public let t: Double
    public let voltage: Double
    public let current: Double
    public let power: Double
    public let resistance: Double

    public func value(_ q: Quantity) -> Double {
        switch q {
        case .voltage: voltage
        case .current: current
        case .power: power
        case .resistance: resistance
        }
    }
}

public enum Quantity: String, CaseIterable, Identifiable, Sendable {
    case voltage, current, power, resistance
    public var id: String { rawValue }
    public var label: String {
        switch self { case .voltage: "Voltage"; case .current: "Current"; case .power: "Power"; case .resistance: "Resistance" }
    }
    public var unit: String {
        switch self { case .voltage: "V"; case .current: "A"; case .power: "W"; case .resistance: "Ω" }
    }
}

/// Bounded in-memory history of live readings (the chart's data source).
/// This is not the run recorder (Phase 3); it keeps the most recent `capacity` samples.
public struct MeasurementHistory: Sendable {
    public private(set) var origin: Date?
    private var buffer: [Sample] = []
    private var head = 0           // index of the oldest sample once full
    public let capacity: Int

    public init(capacity: Int = 200_000) {
        self.capacity = capacity
        buffer.reserveCapacity(min(capacity, 10_000))
    }

    public var count: Int { buffer.count }
    public var isEmpty: Bool { buffer.isEmpty }

    public mutating func append(_ m: Reading) {
        if origin == nil { origin = m.date }
        let s = Sample(t: m.date.timeIntervalSince(origin!), voltage: m.voltage, current: m.current,
                       power: m.power, resistance: m.resistance)
        if buffer.count < capacity { buffer.append(s) }
        else { buffer[head] = s; head = (head + 1) % capacity }
    }

    public mutating func clear() { buffer.removeAll(keepingCapacity: true); head = 0; origin = nil }

    /// Samples in chronological order.
    public var samples: [Sample] {
        head == 0 ? buffer : Array(buffer[head...] + buffer[..<head])
    }

    public var last: Sample? {
        guard !buffer.isEmpty else { return nil }
        return buffer[(head + buffer.count - 1) % buffer.count]
    }

    /// Samples from the last `seconds` (nil = everything), reduced to at most `maxPoints` by
    /// min/max bucketing so pulses and spikes survive downsampling.
    public func window(seconds: Double?, maxPoints: Int = 1200) -> [Sample] {
        let all = samples
        guard let lastT = all.last?.t else { return [] }
        let start = seconds.map { lastT - $0 } ?? -.infinity
        let lo = all.firstIndex { $0.t >= start } ?? all.count
        let slice = Array(all[lo...])
        return Self.minMaxDownsample(slice, maxPoints: maxPoints)
    }

    /// Keeps first/last of each bucket plus the samples holding the bucket's min and max
    /// current and voltage (deduplicated, in time order).
    static func minMaxDownsample(_ s: [Sample], maxPoints: Int) -> [Sample] {
        guard s.count > maxPoints, maxPoints >= 8 else { return s }
        let buckets = maxPoints / 4
        let size = Double(s.count) / Double(buckets)
        var out: [Sample] = []
        out.reserveCapacity(maxPoints)
        for b in 0..<buckets {
            let lo = Int(Double(b) * size), hi = min(Int(Double(b + 1) * size), s.count)
            guard lo < hi else { continue }
            var idx: Set<Int> = [lo, hi - 1]
            var iMin = lo, iMax = lo, vMin = lo, vMax = lo
            for i in lo..<hi {
                if s[i].current < s[iMin].current { iMin = i }
                if s[i].current > s[iMax].current { iMax = i }
                if s[i].voltage < s[vMin].voltage { vMin = i }
                if s[i].voltage > s[vMax].voltage { vMax = i }
            }
            idx.formUnion([iMin, iMax, vMin, vMax])
            out.append(contentsOf: idx.sorted().map { s[$0] })
        }
        return out
    }
}
