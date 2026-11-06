import SwiftUI
import Charts
import AppKit
import LoadLabCore
import SDLKit

/// Run library: every recorded run, with detail, comparison, analysis and export.
struct LibraryView: View {
    @Bindable var library: LibraryModel
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\RunEntry.started, order: .reverse)]
    @State private var search = ""

    private var rows: [RunEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? library.entries : library.entries.filter {
            [$0.title, $0.chemistry, $0.info.cell.notes, $0.setpoint, $0.info.endReason?.label ?? ""]
                .contains { $0.lowercased().contains(q) }
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                header
                table
            }
            // Keep the table compact so the detail/compare view gets the room.
            .frame(minHeight: 150, idealHeight: 210, maxHeight: 340)
            detail
                .frame(minHeight: 420, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .task {
            await library.reload()
            // Test hook: LOADLAB_SELECT_RUNS=1,3 preselects rows (1-based, current sort order).
            if let spec = ProcessInfo.processInfo.environment["LOADLAB_SELECT_RUNS"] {
                let idx = spec.split(separator: ",").compactMap { Int($0) }
                selection = Set(idx.compactMap { $0 >= 1 && $0 <= rows.count ? rows[$0 - 1].id : nil })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Runs").font(.title3.weight(.semibold))
            Text("\(library.entries.count)").foregroundStyle(.secondary)
            if library.loading { ProgressView().controlSize(.small) }
            Spacer()
            TextField("Search title, chemistry, notes…", text: $search)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            Button { Task { await library.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload runs from disk")
            Button { NSWorkspace.shared.open(library.store.root) } label: { Image(systemName: "folder") }
                .help("Open the runs folder in Finder")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Started", value: \.started) { e in
                Text(e.started.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
            }
            .width(min: 120, ideal: 150)
            TableColumn("Title", value: \.title) { e in
                HStack(spacing: 6) {
                    if e.info.status == .running { Image(systemName: "record.circle").foregroundStyle(.red) }
                    Text(e.title)
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Chemistry", value: \.chemistry).width(min: 60, ideal: 80)
            TableColumn("Load", value: \.setpoint).width(min: 70, ideal: 90)
            TableColumn("Capacity", value: \.capacity) { e in
                Text("\(e.capacity.formatted(.number.precision(.fractionLength(e.capacity < 100 ? 1 : 0)))) mAh").monospacedDigit()
            }
            .width(min: 80, ideal: 95)
            TableColumn("Energy", value: \.energy) { e in
                Text("\(e.energy.formatted(.number.precision(.fractionLength(2)))) Wh").monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Duration", value: \.duration) { e in Text(formatDuration(e.duration)).monospacedDigit() }
                .width(min: 60, ideal: 75)
            TableColumn("Result") { e in Text(resultText(e)).foregroundStyle(resultColor(e)) }
                .width(min: 100, ideal: 170)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let e = ids.first.flatMap(library.entry) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([e.folder]) }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        let chosen = rows.filter { selection.contains($0.id) }
        if chosen.count == 1, let e = chosen.first {
            RunDetailView(library: library, entry: e)
                .id(e.id)
        } else if chosen.count > 1 {
            CompareView(library: library, entries: Array(chosen.prefix(seriesPalette.count)))
                .id(chosen.map(\.id))
        } else {
            ContentUnavailableView("Select a run",
                                   systemImage: "battery.100percent.bolt",
                                   description: Text(library.entries.isEmpty
                                                     ? "Runs recorded from the Battery screen appear here."
                                                     : "Select one run for details, or several (⌘-click) to overlay their discharge curves."))
        }
    }

    private func resultText(_ e: RunEntry) -> String {
        switch e.info.status {
        case .running: "Recording…"
        case .failed: "Failed"
        default: e.info.endReason?.label ?? e.info.status.rawValue.capitalized
        }
    }
    private func resultColor(_ e: RunEntry) -> Color {
        switch e.info.endReason {
        case .voltageCutoff, .capacityLimit, .timeLimit: .primary
        case .none: e.info.status == .running ? .red : .secondary
        default: .orange
        }
    }
}

func formatDuration(_ s: Double) -> String {
    let t = Int(max(0, s))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Single run

struct RunDetailView: View {
    @Bindable var library: LibraryModel
    let entry: RunEntry

    enum Kind: String, CaseIterable, Identifiable {
        case discharge = "Discharge curve", time = "V & I vs time", incremental = "dQ/dV"
        var id: String { rawValue }
    }

    @State private var samples: [RunSample] = []
    @State private var analysis = RunAnalysis()
    @State private var loading = true
    @State private var kind: Kind = .discharge
    @State private var xAxis: CurveXAxis = .capacity
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if loading {
                    ProgressView("Loading samples…").frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    MetricsGrid(entry: entry, analysis: analysis)
                    chartControls
                    chart.frame(height: 300)
                    if let dcr = entry.info.dcrResults, !dcr.isEmpty { DCRResultsView(results: dcr) }
                    if !analysis.resistanceSteps.isEmpty { resistanceTable }
                    events
                }
            }
            .padding(20)
        }
        .task {
            samples = await library.samples(for: entry)
            analysis = RunAnalysis.compute(info: entry.info, samples: samples)
            loading = false
            // Test hook: LOADLAB_EXPORT_REPORT=/path.pdf writes the report without a dialog.
            if let path = ProcessInfo.processInfo.environment["LOADLAB_EXPORT_REPORT"] {
                try? Exporter.pdfData(RunReport(entry: entry, analysis: analysis, samples: samples))
                    .write(to: URL(fileURLWithPath: path))
            }
        }
        .sheet(isPresented: $editing) { EditRunSheet(library: library, entry: entry) }
        .confirmationDialog("Move “\(entry.title)” to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { try? library.moveToTrash(entry) }
        } message: { Text("The run folder (samples.csv and run.json) goes to the Trash; you can restore it from there.") }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            Button { editing = true } label: { Label("Edit Info", systemImage: "pencil") }
            Menu {
                Button("Chart as PNG…") {
                    Exporter.savePNG(chartForExport, size: CGSize(width: 900, height: 520), suggestedName: Exporter.fileName(entry.title, ".png"))
                }
                Button("One-page PDF report…") {
                    Exporter.savePDF(RunReport(entry: entry, analysis: analysis, samples: samples),
                                     suggestedName: Exporter.fileName(entry.title, " report.pdf"))
                }
                Divider()
                Button("Show CSV in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.folder.appendingPathComponent("samples.csv")])
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .fixedSize()
                .disabled(loading)
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .disabled(entry.info.status == .running)
                .help("Move this run to the Trash")
        }
    }

    private var subtitle: String {
        var parts = [entry.started.formatted(date: .long, time: .shortened), entry.setpoint]
        if entry.info.cell.seriesCells > 1 { parts.append("\(entry.info.cell.seriesCells)S \(entry.chemistry)") } else { parts.append(entry.chemistry) }
        if let t = entry.info.cell.temperatureC { parts.append("\(t.formatted()) °C") }
        return parts.joined(separator: " · ")
    }

    private var chartControls: some View {
        HStack {
            Picker("Chart", selection: $kind) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            Spacer()
            if kind == .discharge {
                Picker("X axis", selection: $xAxis) { ForEach(CurveXAxis.allCases) { Text($0.rawValue).tag($0) } }
                    .frame(maxWidth: 220)
            }
        }
    }

    @ViewBuilder private var chart: some View {
        switch kind {
        case .discharge:
            OverlayChart(series: curveSeries([(entry, samples)], x: xAxis, y: .voltage), xLabel: xAxis.rawValue,
                         yLabel: "Voltage (V)", cutoff: entry.info.battery.stopVoltageEnabled ? entry.info.battery.stopVoltage : nil)
        case .time:
            let s = RunSample.downsample(samples, maxPoints: 1500)
            VStack(spacing: 6) {
                Chart(s) { LineMark(x: .value("Time (h)", $0.t / 3600), y: .value("V", $0.voltage)).foregroundStyle(Color.blue) }
                    .chartYScale(domain: paddedDomain(s.map(\.voltage))).chartYAxisLabel("Voltage (V)")
                Chart(s) { LineMark(x: .value("Time (h)", $0.t / 3600), y: .value("A", $0.current)).foregroundStyle(Color.orange) }
                    .chartYAxisLabel("Current (A)").chartXAxisLabel("Time (h)")
            }
        case .incremental:
            let ic = curveSeries([(entry, samples)], x: .capacity, y: .incremental)
            if ic.first?.points.isEmpty ?? true {
                ContentUnavailableView("Not enough data for dQ/dV", systemImage: "chart.xyaxis.line")
            } else {
                OverlayChart(series: ic, xLabel: "Voltage (V)", yLabel: "dQ/dV (mAh/V)")
            }
        }
    }

    private var chartForExport: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(entry.title): \(kind.rawValue)").font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            chart
        }
        .padding(20)
        .environment(\.colorScheme, .light)
    }

    private var resistanceTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DC resistance from current steps").font(.headline)
            Text("ΔV/ΔI across abrupt current changes. Includes polarisation within one sample period (\((1 / entry.info.options.sampleRateHz).formatted()) s here), so compare runs recorded at the same rate.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Text("Event").foregroundStyle(.secondary)
                    Text("At").foregroundStyle(.secondary)
                    Text("ΔI").foregroundStyle(.secondary)
                    Text("ΔV").foregroundStyle(.secondary)
                    Text("R").foregroundStyle(.secondary)
                }
                .font(.caption)
                ForEach(analysis.resistanceSteps.prefix(30)) { r in
                    GridRow {
                        Text(r.label)
                        Text("\(r.capacity_mAh.formatted(.number.precision(.fractionLength(0)))) mAh").monospacedDigit()
                        Text("\(r.deltaCurrent.formatted(.number.precision(.fractionLength(3)))) A").monospacedDigit()
                        Text("\((r.deltaVoltage * 1000).formatted(.number.precision(.fractionLength(1)))) mV").monospacedDigit()
                        Text("\(r.milliohms.formatted(.number.precision(.fractionLength(1)))) mΩ").monospacedDigit().bold()
                    }
                }
            }
        }
    }

    private var events: some View {
        DisclosureGroup("Events, settings & notes") {
            VStack(alignment: .leading, spacing: 6) {
                if !entry.info.cell.notes.isEmpty { Text(entry.info.cell.notes).padding(.bottom, 4) }
                ForEach(Array(entry.info.events.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .top) {
                        Text(formatDuration(e.t)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text(e.text)
                    }
                }
                Divider()
                Text(settingsSummary(entry.info)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(entry.folder.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            .font(.callout)
            .padding(.top, 6)
        }
    }
}

func settingsSummary(_ i: RunInfo) -> String {
    var stops: [String] = []
    if i.battery.stopVoltageEnabled { stops.append("V ≤ \(i.battery.stopVoltage.formatted()) V") }
    if i.battery.stopCapacityEnabled { stops.append("\(Int(i.battery.stopCapacity)) mAh") }
    if i.battery.stopTimeEnabled { stops.append("\(Int(i.battery.stopTime)) s") }
    if let p = i.profile {
        var s = "Profile “\(p.name)”: " + p.rows.map { String(repeating: "  ", count: $0.depth) + "\($0.step.kind.label) \($0.step.summary)" }.joined(separator: "; ")
        s += ". Cut-off \(p.limits.cutoffVoltage.formatted()) V, max \(p.limits.maxCurrent.formatted()) A, ranges \(p.currentRange.label) / \(p.voltageRange.label), Von failsafe \((p.limits.cutoffVoltage - p.limits.hardwareMargin).formatted()) V; "
        s += "\(i.options.sampleRateHz.formatted()) samples/s. "
        s += [i.deviceModel, i.deviceSerial.map { "s/n \($0)" }, i.deviceFirmware.map { "fw \($0)" }].compactMap { $0 }.joined(separator: " ")
        return s
    }
    var s = "\(i.battery.mode.label) \(i.battery.level.formatted()) \(i.battery.mode.unit), ranges \(i.battery.currentRange.label) / \(i.battery.voltageRange.label); stop: \(stops.joined(separator: ", ")); "
    s += "\(i.options.sampleRateHz.formatted()) samples/s; "
    s += i.savedVOn != nil ? "backup cut-off armed. " : "no backup cut-off. "
    s += [i.deviceModel, i.deviceSerial.map { "s/n \($0)" }, i.deviceFirmware.map { "fw \($0)" }].compactMap { $0 }.joined(separator: " ")
    return s
}

/// Key numbers for one run.
struct MetricsGrid: View {
    let entry: RunEntry
    let analysis: RunAnalysis

    var body: some View {
        let a = analysis
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
            GridRow {
                Metric("Capacity", a.capacity_mAh, "mAh", a.capacity_mAh < 100 ? 2 : 0)
                Metric("Energy", a.energy_Wh, "Wh", 3)
                Metric("Under load", nil, "", text: formatDuration(a.loadedDuration_s))
                Metric("Instrument count", entry.info.summary.deviceCapacity_mAh, "mAh", 0)
                if let soh = a.stateOfHealth { Metric("Of nominal", soh * 100, "%", 1) }
            }
            GridRow {
                Metric("Average V", a.averageVoltage, "V", 3)
                Metric("Midpoint V", a.midpointVoltage, "V", 3)
                Metric("Start / end V", nil, "", text: [a.startVoltage, a.endLoadedVoltage].map { $0.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? "—" }.joined(separator: " / "))
                Metric("Average I", a.averageCurrent, "A", 3)
                if let r = a.resistanceSteps.first(where: { $0.label == "Load applied" }) {
                    Metric("DCR at start", r.milliohms, "mΩ", 1)
                }
            }
        }
    }
}

private struct Metric: View {
    let title: String
    let value: Double?
    let unit: String
    let digits: Int
    var text: String? = nil
    init(_ title: String, _ value: Double?, _ unit: String, _ digits: Int = 2, text: String? = nil) {
        self.title = title; self.value = value; self.unit = unit; self.digits = digits; self.text = text
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(text ?? value.map { $0.formatted(.number.precision(.fractionLength(digits))) } ?? "—")
                    .font(.title3.weight(.medium)).monospacedDigit()
                if !unit.isEmpty, value != nil { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Compare

struct CompareView: View {
    @Bindable var library: LibraryModel
    let entries: [RunEntry]

    @State private var loaded: [(entry: RunEntry, samples: [RunSample])] = []
    @State private var x: CurveXAxis = .capacity
    @State private var y: CurveYAxis = .voltage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Comparing \(entries.count) runs").font(.title2.weight(.semibold))
                    Spacer()
                    Picker("Plot", selection: $y) { ForEach(CurveYAxis.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(width: 200)
                    if y == .voltage {
                        Picker("X axis", selection: $x) { ForEach(CurveXAxis.allCases) { Text($0.rawValue).tag($0) } }
                            .frame(width: 210)
                    }
                    Button {
                        Exporter.savePNG(exportView, size: CGSize(width: 900, height: 560), suggestedName: "Comparison.png")
                    } label: { Label("Export PNG", systemImage: "square.and.arrow.up") }
                        .disabled(loaded.isEmpty)
                }
                if loaded.count < entries.count {
                    ProgressView("Loading \(entries.count) runs…").frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    chart.frame(height: 340)
                    comparisonTable
                }
            }
            .padding(20)
        }
        .task {
            var out: [(RunEntry, [RunSample])] = []
            for e in entries { out.append((e, await library.samples(for: e))) }
            loaded = out
        }
    }

    private var chart: some View {
        OverlayChart(series: curveSeries(loaded, x: x, y: y),
                     xLabel: y == .voltage ? x.rawValue : "Voltage (V)",
                     yLabel: y == .voltage ? "Voltage (V)" : "dQ/dV (mAh/V)")
    }

    private var exportView: some View {
        VStack(alignment: .leading) {
            Text("Discharge comparison").font(.headline)
            chart
        }
        .padding(20)
        .environment(\.colorScheme, .light)
    }

    private var comparisonTable: some View {
        let rows = loaded.enumerated().map { k, r in (k, r.entry, RunAnalysis.compute(info: r.entry.info, samples: r.samples)) }
        let best = rows.map { $0.2.capacity_mAh }.max() ?? 0
        return Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
            GridRow {
                ForEach(["Run", "Date", "Load", "Capacity", "vs best", "Energy", "Avg V", "Mid V", "DCR start", "Of nominal"], id: \.self) {
                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            ForEach(rows, id: \.0) { k, e, a in
                GridRow {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1).fill(seriesPalette[k % seriesPalette.count]).frame(width: 12, height: 3)
                        Text(e.title).lineLimit(1)
                    }
                    Text(e.started.formatted(date: .abbreviated, time: .omitted))
                    Text(e.setpoint)
                    Text("\(a.capacity_mAh.formatted(.number.precision(.fractionLength(0)))) mAh").monospacedDigit()
                    Text(best > 0 ? "\((a.capacity_mAh / best * 100).formatted(.number.precision(.fractionLength(1)))) %" : "—").monospacedDigit()
                    Text("\(a.energy_Wh.formatted(.number.precision(.fractionLength(2)))) Wh").monospacedDigit()
                    Text(a.averageVoltage.map { "\($0.formatted(.number.precision(.fractionLength(3)))) V" } ?? "—").monospacedDigit()
                    Text(a.midpointVoltage.map { "\($0.formatted(.number.precision(.fractionLength(3)))) V" } ?? "—").monospacedDigit()
                    Text(a.resistanceSteps.first { $0.label == "Load applied" }.map { "\($0.milliohms.formatted(.number.precision(.fractionLength(1)))) mΩ" } ?? "—").monospacedDigit()
                    Text(a.stateOfHealth.map { "\(($0 * 100).formatted(.number.precision(.fractionLength(1)))) %" } ?? "—").monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}

// MARK: - Edit

struct EditRunSheet: View {
    @Bindable var library: LibraryModel
    let entry: RunEntry
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var cell = CellInfo()
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Title", text: $title)
                TextField("Cell name", text: $cell.name)
                Picker("Chemistry", selection: $cell.chemistry) { ForEach(CellInfo.chemistries, id: \.self) { Text($0) } }
                Stepper("Cells in series: \(cell.seriesCells)", value: $cell.seriesCells, in: 1...48)
                LabeledContent("Nominal capacity") {
                    TextField("", value: $cell.nominalCapacity_mAh, format: .number, prompt: Text("mAh")).frame(width: 100)
                }
                LabeledContent("Nominal voltage") {
                    TextField("", value: $cell.nominalVoltage, format: .number, prompt: Text("V")).frame(width: 100)
                }
                LabeledContent("Temperature") {
                    TextField("", value: $cell.temperatureC, format: .number, prompt: Text("°C")).frame(width: 100)
                }
                TextField("Notes", text: $cell.notes, axis: .vertical).lineLimit(3...8)
                Text("Measurements and instrument settings can't be edited.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do { try library.update(entry, title: title, cell: cell); dismiss() }
                    catch { self.error = "\(error)" }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 460, height: 520)
        .onAppear { title = entry.title; cell = entry.info.cell }
    }
}

// MARK: - PDF report

struct RunReport: View {
    let entry: RunEntry
    let analysis: RunAnalysis
    let samples: [RunSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title).font(.system(size: 20, weight: .semibold))
                Spacer()
                Text("LoadLab discharge report").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text("\(entry.started.formatted(date: .long, time: .shortened)) · \(entry.setpoint) · \(entry.chemistry) · \(entry.info.endReason?.label ?? entry.info.status.rawValue)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            MetricsGrid(entry: entry, analysis: analysis).scaleEffect(0.82, anchor: .topLeading).frame(height: 96, alignment: .topLeading)
            Text("Voltage vs capacity").font(.system(size: 11, weight: .semibold))
            OverlayChart(series: curveSeries([(entry, samples)], x: .capacity, y: .voltage), xLabel: "Capacity (mAh)",
                         yLabel: "Voltage (V)", cutoff: entry.info.battery.stopVoltageEnabled ? entry.info.battery.stopVoltage : nil)
                .frame(height: 250)
            Text("Voltage and current vs time").font(.system(size: 11, weight: .semibold))
            let s = RunSample.downsample(samples, maxPoints: 800)
            HStack(spacing: 12) {
                Chart(s) { LineMark(x: .value("h", $0.t / 3600), y: .value("V", $0.voltage)).foregroundStyle(Color.blue) }
                    .chartYScale(domain: paddedDomain(s.map(\.voltage))).chartYAxisLabel("V").chartXAxisLabel("Time (h)")
                Chart(s) { LineMark(x: .value("h", $0.t / 3600), y: .value("A", $0.current)).foregroundStyle(Color.orange) }
                    .chartYAxisLabel("A").chartXAxisLabel("Time (h)")
            }
            .frame(height: 150)
            if !entry.info.cell.notes.isEmpty {
                Text("Notes: \(entry.info.cell.notes)").font(.system(size: 9))
            }
            Text(settingsSummary(entry.info)).font(.system(size: 8)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(36)
        .environment(\.colorScheme, .light)
    }
}
