import SwiftUI
import AppKit
import Charts
import LoadLabCore
import SDLKit

/// Battery function: plan a discharge test, run and record it.
struct BatteryPane: View {
    @Bindable var session: DeviceSession

    var body: some View {
        if let r = session.recorder {
            RunDashboard(session: session, recorder: r)
        } else {
            BatterySetup(session: session)
        }
    }
}

// MARK: - Setup

private struct BatterySetup: View {
    @Bindable var session: DeviceSession

    @State private var config = BatteryConfig()
    @State private var cell = CellInfo()
    @State private var options = RecordingOptions()
    @State private var loaded = false
    @State private var confirming = false
    @State private var starting = false
    @State private var startError: String?

    @AppStorage("battery.lastCell") private var savedCell: Data = Data()
    @AppStorage("battery.lastOptions") private var savedOptions: Data = Data()

    var body: some View {
        Form {
            if session.state.function != .battery {
                Section {
                    HStack {
                        Label("The instrument is in \(session.state.function.label). Settings are sent when you start the test.", systemImage: "info.circle")
                        Spacer()
                        Button("Switch to Battery now") { Task { await session.enterBattery(); config = session.state.battery } }
                    }
                }
            }
            cellSection
            dischargeSection
            stopSection
            recordingSection
            Section {
                HStack {
                    if let startError {
                        Label(startError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if !config.hasStopCondition {
                        Label("Enable at least one stop condition.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        confirming = true
                    } label: {
                        Label(starting ? "Starting…" : "Start Discharge Test", systemImage: "play.fill")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!config.hasStopCondition || starting || !session.link.isUsable)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .confirmationDialog("Start discharge test?", isPresented: $confirming) {
            Button("Start (input ON)") { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(summary)
        }
    }

    // Sections

    private var cellSection: some View {
        Section("Cell / pack") {
            TextField("Name", text: $cell.name, prompt: Text("e.g. Samsung 30Q #3"))
            Picker("Chemistry", selection: $cell.chemistry) {
                ForEach(CellInfo.chemistries, id: \.self) { Text($0) }
            }
            Stepper("Cells in series: \(cell.seriesCells)", value: $cell.seriesCells, in: 1...48)
            OptionalNumberRow(label: "Nominal capacity", value: $cell.nominalCapacity_mAh, unit: "mAh")
            OptionalNumberRow(label: "Nominal voltage", value: $cell.nominalVoltage, unit: "V")
            OptionalNumberRow(label: "Temperature", value: $cell.temperatureC, unit: "°C")
            TextField("Notes", text: $cell.notes, axis: .vertical).lineLimit(1...4)
        }
    }

    private var dischargeSection: some View {
        Section {
            Picker("Mode", selection: $config.mode) {
                ForEach(BatteryMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            NumberRow(label: config.mode == .cc ? "Discharge current" : config.mode == .cp ? "Discharge power" : "Load resistance",
                      value: $config.level, unit: config.mode.unit, range: config.levelRange)
            if config.mode == .cc, let nominal = cell.nominalCapacity_mAh, nominal > 0 {
                LabeledContent("C-rate") {
                    HStack {
                        Text((config.level * 1000 / nominal).formatted(.number.precision(.fractionLength(2))) + " C")
                            .monospacedDigit()
                        ForEach([0.2, 0.5, 1.0], id: \.self) { c in
                            Button("\(c.formatted()) C") { config.level = min(nominal * c / 1000, config.levelRange.upperBound) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Picker("Current range", selection: $config.currentRange) {
                ForEach(CurrentRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Voltage range", selection: $config.voltageRange) {
                ForEach(VoltageRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if config.mode == .cr {
                Picker("Resistance range", selection: $config.resistanceRange) {
                    ForEach(ResistanceRange.allCases) { Text($0.label).tag($0) }
                }
            }
        } header: {
            Text("Discharge")
        } footer: {
            Text("Use the 5 A / 36 V ranges for better resolution when the test stays within them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stopSection: some View {
        Section {
            HStack {
                Toggle("Stop at voltage", isOn: $config.stopVoltageEnabled)
                Spacer()
                NumberField(value: $config.stopVoltage, unit: "V").disabled(!config.stopVoltageEnabled)
            }
            if let s = cell.suggestedCutoff, abs(s - config.stopVoltage) > 0.001 {
                Button("Use \(s.formatted()) V (typical for \(cell.seriesCells)× \(cell.chemistry))") {
                    config.stopVoltage = s; config.stopVoltageEnabled = true
                }
                .buttonStyle(.link).font(.caption)
            }
            HStack {
                Toggle("Stop at capacity", isOn: $config.stopCapacityEnabled)
                Spacer()
                NumberField(value: $config.stopCapacity, unit: "mAh", digits: 0).disabled(!config.stopCapacityEnabled)
            }
            HStack {
                Toggle("Stop after time", isOn: $config.stopTimeEnabled)
                Spacer()
                NumberField(value: Binding(get: { config.stopTime / 60 }, set: { config.stopTime = ($0 * 60).rounded() }),
                            unit: "min", digits: 1).disabled(!config.stopTimeEnabled)
            }
        } header: {
            Text("Stop conditions (enforced by the instrument)")
        } footer: {
            Text("The SDL ends the test when any enabled condition is met, even if LoadLab disconnects.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recordingSection: some View {
        Section {
            Picker("Sample rate", selection: $options.sampleRateHz) {
                ForEach([0.5, 1, 2, 5, 10], id: \.self) { hz in Text(hz < 1 ? "every 2 s" : "\(Int(hz)) per second").tag(hz) }
            }
            Toggle(isOn: $options.hardwareCutoff) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backup hardware cut-off")
                    Text(config.stopVoltageEnabled
                         ? "Sets Von to \((max(0, config.stopVoltage - options.hardwareCutoffMargin)).formatted()) V with latch off for the run, so the load stops below the cut-off even without LoadLab. Your Von settings are restored afterwards."
                         : "Needs a stop voltage.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!config.stopVoltageEnabled)
            LabeledContent("Saved to") {
                Button(session.runStore.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    try? FileManager.default.createDirectory(at: session.runStore.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(session.runStore.root)
                }
                .buttonStyle(.link)
            }
        } header: {
            Text("Recording")
        }
    }

    // Actions

    private var summary: String {
        var lines = ["\(config.mode.label) \(config.level.formatted()) \(config.mode.unit) from \(cell.name.isEmpty ? "the connected cell" : cell.name)."]
        var stops: [String] = []
        if config.stopVoltageEnabled { stops.append("≤ \(config.stopVoltage.formatted()) V") }
        if config.stopCapacityEnabled { stops.append("\(Int(config.stopCapacity)) mAh") }
        if config.stopTimeEnabled { stops.append("\((config.stopTime / 60).formatted()) min") }
        lines.append("Stops at " + stops.joined(separator: " or ") + ".")
        if options.hardwareCutoff && config.stopVoltageEnabled { lines.append("Backup hardware cut-off armed.") }
        lines.append("The input switches ON immediately.")
        return lines.joined(separator: " ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        config = session.state.battery
        if let c = try? JSONDecoder().decode(CellInfo.self, from: savedCell) { cell = c }
        if let o = try? JSONDecoder().decode(RecordingOptions.self, from: savedOptions) { options = o }
    }

    private func start() {
        startError = nil
        starting = true
        savedCell = (try? JSONEncoder().encode(cell)) ?? Data()
        savedOptions = (try? JSONEncoder().encode(options)) ?? Data()
        Task {
            do { try await session.startBatteryRun(config: config, cell: cell, options: options) }
            catch { startError = "\(error)" }
            starting = false
        }
    }
}

// MARK: - Run dashboard

private struct RunDashboard: View {
    @Bindable var session: DeviceSession
    let recorder: RunRecorder

    enum ChartKind: String, CaseIterable, Identifiable {
        case vVsCapacity = "Voltage vs capacity", vAndITime = "Voltage & current vs time", power = "Power vs time"
        var id: String { rawValue }
    }
    @State private var chart: ChartKind = .vVsCapacity
    @State private var notes = ""

    private var info: RunInfo { recorder.info }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                stats
                Picker("Chart", selection: $chart) {
                    ForEach(ChartKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                RunChart(kind: chart, samples: RunSample.downsample(recorder.samples), cutoff: info.battery.stopVoltageEnabled ? info.battery.stopVoltage : nil)
                    .frame(minHeight: 260)
                details
            }
            .padding(20)
        }
        .onAppear { notes = info.cell.notes }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.title).font(.title2.weight(.semibold))
                Text("\(info.battery.mode.label) \(info.battery.level.formatted()) \(info.battery.mode.unit) · started \(info.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            statusBadge
            Spacer()
            if recorder.isActive {
                Button(role: .destructive) { Task { await session.stopRun() } } label: {
                    Label("Stop Test", systemImage: "stop.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            } else {
                Button { NSWorkspace.shared.activateFileViewerSelecting([recorder.folder.appendingPathComponent("samples.csv")]) } label: {
                    Label("Show Files", systemImage: "folder")
                }
                Button { session.dismissRun() } label: { Label("New Test", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = switch info.status {
        case .running: ("● Recording", .red)
        case .completed: ("Completed", .green)
        case .stopped: ("Stopped", .orange)
        case .interrupted: ("Interrupted", .orange)
        case .failed: ("Failed", .red)
        }
        return StatusChip(text: text, tint: color)
    }

    private var stats: some View {
        let last = recorder.samples.last
        let cap = recorder.integrator.capacity_mAh
        return Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
            GridRow {
                Stat(title: "Elapsed", value: Self.duration(recorder.isActive ? Date().timeIntervalSince(info.startedAt) : info.summary.duration_s))
                Stat(title: "Capacity", value: cap.formatted(.number.precision(.fractionLength(cap < 100 ? 2 : 1))), unit: "mAh", color: .orange)
                Stat(title: "Energy", value: recorder.integrator.energy_Wh.formatted(.number.precision(.fractionLength(3))), unit: "Wh", color: .pink)
                Stat(title: "Instrument count", value: recorder.deviceCapacity.map { "\(Int($0))" } ?? "—", unit: "mAh")
                    .help("The SDL's own counter (1 mAh resolution), for cross-checking.")
            }
            GridRow {
                Stat(title: "Voltage", value: last.map { $0.voltage.formatted(.number.precision(.fractionLength(4))) } ?? "—", unit: "V", color: .blue)
                Stat(title: "Current", value: last.map { $0.current.formatted(.number.precision(.fractionLength(4))) } ?? "—", unit: "A", color: .orange)
                if let nominal = info.cell.nominalCapacity_mAh, nominal > 0 {
                    Stat(title: "Of nominal", value: (cap / nominal * 100).formatted(.number.precision(.fractionLength(1))), unit: "%")
                    if recorder.isActive, let i = last?.current, i > 0.001, nominal > cap {
                        Stat(title: "Time to nominal", value: Self.duration((nominal - cap) / (i * 1000) * 3600))
                    }
                }
                if !recorder.isActive, let reason = info.endReason {
                    Stat(title: "Ended", value: reason.label)
                }
            }
        }
    }

    private var details: some View {
        DisclosureGroup("Details, events & notes") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .onSubmit { recorder.setNotes(notes) }
                    .onChange(of: notes) { _, n in if !recorder.isActive { recorder.setNotes(n) } }
                ForEach(Array(info.events.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .top) {
                        Text(Self.duration(e.t)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        Text(e.text)
                    }
                    .font(.callout)
                }
                Text(recorder.folder.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            .padding(.top, 6)
        }
    }

    static func duration(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

private struct Stat: View {
    let title: String
    let value: String
    var unit: String = ""
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.weight(.medium)).monospacedDigit()
                if !unit.isEmpty { Text(unit).foregroundStyle(color == .primary ? .secondary : color) }
            }
        }
    }
}

private struct RunChart: View {
    let kind: RunDashboard.ChartKind
    let samples: [RunSample]
    let cutoff: Double?

    var body: some View {
        if samples.count < 2 {
            ContentUnavailableView("Waiting for data", systemImage: "chart.xyaxis.line")
        } else {
            switch kind {
            case .vVsCapacity:
                Chart {
                    ForEach(samples.filter { $0.current > 0.001 }) {
                        LineMark(x: .value("Capacity (mAh)", $0.capacity_mAh), y: .value("Voltage (V)", $0.voltage))
                            .foregroundStyle(Color.blue)
                    }
                    if let cutoff { RuleMark(y: .value("Cut-off", cutoff)).foregroundStyle(.red.opacity(0.6)).lineStyle(StrokeStyle(dash: [4, 4])) }
                }
                .chartXAxisLabel("Capacity (mAh)")
                .chartYAxisLabel("Voltage (V)")
                .chartYScale(domain: .automatic(includesZero: false))
            case .vAndITime:
                VStack(spacing: 8) {
                    Chart(samples) { LineMark(x: .value("Time", $0.t / 60), y: .value("V", $0.voltage)).foregroundStyle(Color.blue) }
                        .chartYScale(domain: .automatic(includesZero: false))
                        .chartYAxisLabel("Voltage (V)")
                    Chart(samples) { LineMark(x: .value("Time", $0.t / 60), y: .value("A", $0.current)).foregroundStyle(Color.orange) }
                        .chartYAxisLabel("Current (A)")
                        .chartXAxisLabel("Time (min)")
                }
            case .power:
                Chart(samples) { LineMark(x: .value("Time", $0.t / 60), y: .value("W", $0.power)).foregroundStyle(Color.pink) }
                    .chartYAxisLabel("Power (W)")
                    .chartXAxisLabel("Time (min)")
            }
        }
    }
}

// MARK: - Draft number inputs (plain bindings; applied when the test starts)

private struct NumberField: View {
    @Binding var value: Double
    let unit: String
    var digits = 3
    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...digits)).grouping(.never))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 100)
            Text(unit).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .leading)
        }
    }
}

private struct NumberRow: View {
    let label: String
    @Binding var value: Double
    let unit: String
    var range: ClosedRange<Double>? = nil
    var body: some View {
        LabeledContent(label) {
            NumberField(value: Binding(get: { value }, set: { new in
                value = range.map { r in min(max(new, r.lowerBound), r.upperBound) } ?? new
            }), unit: unit)
        }
    }
}

private struct OptionalNumberRow: View {
    let label: String
    @Binding var value: Double?
    let unit: String
    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number.grouping(.never), prompt: Text("optional"))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit().frame(width: 100)
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .leading)
            }
        }
    }
}
