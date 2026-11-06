import SwiftUI
import Charts
import LoadLabCore

/// Live stacked charts (one per selected quantity, shared time axis). Replaces EasySDL's
/// "Trend" popup. Each quantity gets its own y-scale, so V and A are both readable.
struct LiveChartView: View {
    let session: DeviceSession

    @AppStorage("chart.window") private var windowSeconds: Double = 60
    @AppStorage("chart.showV") private var showV = true
    @AppStorage("chart.showI") private var showI = true
    @AppStorage("chart.showP") private var showP = false
    @AppStorage("chart.showR") private var showR = false
    @State private var paused = false
    @State private var frozen: [Sample] = []

    private let windows: [(String, Double)] = [("30 s", 30), ("1 min", 60), ("5 min", 300), ("30 min", 1800), ("2 h", 7200), ("All", 0)]

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            let data = paused ? frozen : session.history.window(seconds: windowSeconds == 0 ? nil : windowSeconds)
            if data.isEmpty {
                ContentUnavailableView("No data yet", systemImage: "waveform.path.ecg",
                                       description: Text("Readings appear here once connected."))
            } else {
                VStack(spacing: 6) {
                    ForEach(selected) { q in
                        QuantityChart(quantity: q, samples: data)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var selected: [Quantity] {
        var out: [Quantity] = []
        if showV { out.append(.voltage) }
        if showI { out.append(.current) }
        if showP { out.append(.power) }
        if showR { out.append(.resistance) }
        return out
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Toggle("V", isOn: $showV).toggleStyle(.button).tint(Quantity.voltage.color)
            Toggle("A", isOn: $showI).toggleStyle(.button).tint(Quantity.current.color)
            Toggle("W", isOn: $showP).toggleStyle(.button).tint(Quantity.power.color)
            Toggle("Ω", isOn: $showR).toggleStyle(.button).tint(Quantity.resistance.color)
            Spacer()
            Picker("Window", selection: $windowSeconds) {
                ForEach(windows, id: \.1) { Text($0.0).tag($0.1) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Button {
                if !paused { frozen = session.history.window(seconds: windowSeconds == 0 ? nil : windowSeconds) }
                paused.toggle()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
            }
            .help(paused ? "Resume live view" : "Freeze the chart")
            Button { session.clearHistory(); frozen = [] } label: { Image(systemName: "trash") }
                .help("Clear the live history (does not affect recordings)")
        }
        .controlSize(.small)
    }
}

extension Quantity {
    /// Smallest y-span shown, so noise on a steady reading isn't blown up full-height.
    var minimumSpan: Double {
        switch self { case .voltage: 0.05; case .current: 0.01; case .power: 0.05; case .resistance: 0.5 }
    }
}

private struct QuantityChart: View {
    let quantity: Quantity
    let samples: [Sample]

    var body: some View {
        let values = samples.map { $0.value(quantity) }
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        // Flat signals would collapse the axis; enforce a minimum visible span.
        let span = max(hi - lo, max(abs(hi) * 0.02, quantity.minimumSpan))
        let mid = (hi + lo) / 2
        let domain = (mid - span * 0.6)...(mid + span * 0.6)
        return VStack(alignment: .leading, spacing: 2) {
        Text("\(quantity.label) (\(quantity.unit))")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(quantity.color)
        Chart(samples) { s in
            LineMark(x: .value("Time", s.t), y: .value(quantity.label, s.value(quantity)))
                .foregroundStyle(quantity.color)
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { v in
                AxisGridLine()
                AxisValueLabel { if let t = v.as(Double.self) { Text(Self.timeLabel(t)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4))
        }
        .chartYScale(domain: domain)
        .frame(minHeight: 80)
        }
    }

    static func timeLabel(_ t: Double) -> String {
        let s = Int(t.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
