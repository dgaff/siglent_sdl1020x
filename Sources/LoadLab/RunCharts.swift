import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import LoadLabCore

/// One line on an overlay chart.
struct ChartSeries: Identifiable {
    let id: String
    let name: String
    let color: Color
    let points: [CGPoint]
}

/// Data range padded by 6 % (minimum span keeps flat lines readable).
func paddedDomain(_ values: [Double], minSpan: Double = 0.05) -> ClosedRange<Double> {
    guard let lo = values.min(), let hi = values.max() else { return 0...1 }
    let span = max(hi - lo, minSpan)
    let mid = (hi + lo) / 2
    return (mid - span * 0.56)...(mid + span * 0.56)
}

/// Series palette for comparisons (distinct in light and dark mode).
let seriesPalette: [Color] = [.blue, .orange, .green, .purple, .red, .teal, .brown, .pink, .indigo, .mint]

/// X axis choices for discharge curves.
enum CurveXAxis: String, CaseIterable, Identifiable {
    case capacity = "Capacity (mAh)", percent = "% of nominal", energy = "Energy (Wh)", time = "Time (h)"
    var id: String { rawValue }

    func x(_ s: RunSample, nominal: Double?, total: Double) -> Double {
        switch self {
        case .capacity: s.capacity_mAh
        case .percent: s.capacity_mAh / (nominal ?? max(total, 1e-9)) * 100
        case .energy: s.energy_Wh
        case .time: s.t / 3600
        }
    }
}

enum CurveYAxis: String, CaseIterable, Identifiable {
    case voltage = "Voltage", incremental = "dQ/dV"
    var id: String { rawValue }
}

/// Builds plotted series for runs (loaded samples only, downsampled).
@MainActor
func curveSeries(_ runs: [(entry: RunEntry, samples: [RunSample])], x: CurveXAxis, y: CurveYAxis) -> [ChartSeries] {
    runs.enumerated().map { k, r in
        let color = seriesPalette[k % seriesPalette.count]
        let pts: [CGPoint]
        switch y {
        case .voltage:
            let loaded = RunSample.downsample(r.samples.filter { $0.current > RunAnalysis.currentFloor }, maxPoints: 1200)
            let total = loaded.last?.capacity_mAh ?? 0
            pts = loaded.map { CGPoint(x: x.x($0, nominal: r.entry.info.cell.nominalCapacity_mAh, total: total), y: $0.voltage) }
        case .incremental:
            pts = RunAnalysis.incrementalCapacity(r.samples).map { CGPoint(x: $0.voltage, y: $0.dQdV) }
        }
        return ChartSeries(id: r.entry.id.uuidString, name: r.entry.title, color: color, points: pts)
    }
}

/// Overlay line chart with a legend.
struct OverlayChart: View {
    let series: [ChartSeries]
    let xLabel: String
    let yLabel: String
    var cutoff: Double? = nil
    var showLegend = true

    private struct PlotPoint: Identifiable {
        let id: Int
        let run: String
        let x: Double
        let y: Double
    }

    private var plotPoints: [PlotPoint] {
        var out: [PlotPoint] = []
        for s in series {
            for p in s.points { out.append(PlotPoint(id: out.count, run: s.id, x: p.x, y: p.y)) }
        }
        return out
    }

    private var yDomain: ClosedRange<Double> {
        var ys: [Double] = []
        for s in series { for p in s.points { ys.append(Double(p.y)) } }
        if let cutoff { ys.append(cutoff) }
        return paddedDomain(ys)
    }

    var body: some View {
        let ids = series.map(\.id)
        let colors = series.map(\.color)
        return Chart {
            ForEach(plotPoints) { p in
                LineMark(x: .value("x", p.x), y: .value("y", p.y), series: .value("Run", p.run))
                    .foregroundStyle(by: .value("Run", p.run))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
            if let cutoff {
                RuleMark(y: .value("Cut-off", cutoff))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartForegroundStyleScale(domain: ids, range: colors)
        .chartXAxisLabel(xLabel)
        .chartYAxisLabel(yLabel)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .overlay(alignment: .topTrailing) {
            if showLegend && series.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(series) { s in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1).fill(s.color).frame(width: 14, height: 3)
                            Text(s.name).font(.caption).lineLimit(1)
                        }
                    }
                }
                .padding(8)
                .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
            }
        }
    }
}

// MARK: - Export helpers

@MainActor
enum Exporter {
    /// Renders a view to PNG (2× scale) and asks where to save it.
    static func savePNG<V: View>(_ view: V, size: CGSize, suggestedName: String) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color.white))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        save(data: png, type: .png, suggestedName: suggestedName)
    }

    /// Renders a view as a single-page PDF (US Letter) and asks where to save it.
    static func savePDF<V: View>(_ view: V, suggestedName: String) {
        save(data: pdfData(view), type: .pdf, suggestedName: suggestedName)
    }

    static func pdfData<V: View>(_ view: V) -> Data {
        let page = CGSize(width: 612, height: 792)
        let renderer = ImageRenderer(content: view.frame(width: page.width, height: page.height).background(Color.white))
        let data = NSMutableData()
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: page)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
        }
        return data as Data
    }

    static func save(data: Data, type: UTType, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    static func fileName(_ title: String, _ suffix: String) -> String {
        let clean = title.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " ? $0 : "_" }
        return String(clean).trimmingCharacters(in: .whitespaces) + suffix
    }
}
