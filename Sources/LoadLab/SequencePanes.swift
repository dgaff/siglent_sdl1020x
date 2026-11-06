import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers
import LoadLabCore
import SDLKit

// MARK: - Shared pieces

/// "The instrument is in X" banner with a switch button.
private struct FunctionBanner: View {
    let session: DeviceSession
    let function: ActiveFunction
    var title: String? = nil

    var body: some View {
        if let r = session.recorder, r.isActive {
            Label(r.info.kind == "profile" ? "A profile is running. This screen is locked until it ends."
                                           : "A battery test is recording. This screen is locked until it ends.",
                  systemImage: "lock.fill")
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        } else if let q = session.sequence, q.phase == .running, q.function != function, !(q.function == .oppt && function == .ocpt) {
            Label("A \(q.function.label) run is in progress. This screen is locked until it ends.", systemImage: "lock.fill")
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        } else if session.state.function != function {
            HStack {
                Label("The instrument is in \(session.state.function.label). Settings here are sent when you switch or press Send.",
                      systemImage: "info.circle")
                Spacer()
                Button("Switch to \(title ?? function.label)") { Task { await session.enterFunction(function) } }
                    .disabled(busy(session))
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

@MainActor
private func busy(_ s: DeviceSession) -> Bool {
    s.sequence?.phase == .running || s.recorder?.isActive == true || !s.link.isUsable
}

/// Send / Revert for a draft, with validation messages.
private struct DraftBar: View {
    let dirty: Bool
    let problems: [String]
    let sending: Bool
    let disabled: Bool
    let send: () -> Void
    let revert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            HStack {
                if dirty { Label("Edited — not yet on the instrument", systemImage: "pencil").foregroundStyle(.secondary) }
                Spacer()
                Button("Revert", action: revert).disabled(!dirty || sending)
                Button(sending ? "Sending…" : "Send to Instrument", action: send)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty || sending || disabled || !problems.isEmpty)
            }
        }
    }
}

/// Run / Stop buttons plus status for List, Program and OCPT/OPPT.
private struct RunControls: View {
    let session: DeviceSession
    let function: ActiveFunction
    let ready: Bool
    let confirmText: String
    var stepTotal: Int? = nil
    @State private var confirming = false
    @State private var error: String?

    private var run: SequenceRun? { session.sequence?.function == function ? session.sequence : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let r = run {
                    switch r.phase {
                    case .running:
                        ProgressView().controlSize(.small)
                        if let n = stepTotal, function == .list || function == .program {
                            Text(r.step == 0 ? "Starting…" : "Step \(min(r.step, n)) of \(n)").monospacedDigit()
                        } else {
                            Text("Running").foregroundStyle(.secondary)
                        }
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(RunDashboard.duration(ctx.date.timeIntervalSince(r.started))).monospacedDigit().foregroundStyle(.secondary)
                        }
                    case .finished: StatusChip(text: "Finished", tint: .green)
                    case .stopped: StatusChip(text: "Stopped", tint: .orange)
                    }
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2) }
                Spacer()
                if run?.phase == .running {
                    Button(role: .destructive) { Task { await session.stopSequence() } } label: {
                        Label("Stop", systemImage: "stop.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                } else {
                    if run != nil { Button("Clear Result") { session.dismissSequence() } }
                    Button { confirming = true } label: {
                        Label("Run", systemImage: "play.fill").padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!ready || busy(session) || session.state.function != function)
                }
            }
        }
        .confirmationDialog("Run \(function == .ocpt ? "OCPT" : function == .oppt ? "OPPT" : function.label)?", isPresented: $confirming) {
            Button("Run (input ON)") {
                error = nil
                Task {
                    do { try await session.startSequence(function) } catch { self.error = "\(error)" }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text(confirmText) }
    }
}

/// Compact number cell for tables.
private struct CellNumber: View {
    @Binding var value: Double
    var width: CGFloat = 80
    var body: some View {
        TextField("", value: $value, format: .number.precision(.fractionLength(0...6)).grouping(.never))
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).monospacedDigit().frame(width: width)
    }
}

@MainActor
private enum CSVFiles {
    static func export(_ text: String, name: String) {
        let p = NSSavePanel()
        p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = name
        guard p.runModal() == .OK, let url = p.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    static func importText() -> String? {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText, .plainText]
        p.allowsMultipleSelection = false
        guard p.runModal() == .OK, let url = p.url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - List

struct ListPane: View {
    @Bindable var session: DeviceSession
    @State private var draft = ListConfig()
    @State private var loaded = false
    @State private var sending = false
    @State private var selection = Set<ListStep.ID>()
    @State private var importError: String?

    private var dirty: Bool { !same(draft, session.state.list) }
    private var locked: Bool { busy(session) }
    private var runningStep: Int? {
        guard let r = session.sequence, r.function == .list, r.phase == .running else { return nil }
        return r.step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FunctionBanner(session: session, function: .list)
            settings
            table
            HStack {
                Button { addStep() } label: { Label("Add Step", systemImage: "plus") }
                    .disabled(locked || draft.steps.count >= SDLLimits.listSteps.upperBound)
                Button { draft.steps.removeAll { selection.contains($0.id) } } label: { Label("Delete", systemImage: "minus") }
                    .disabled(locked || selection.isEmpty || draft.steps.count <= selection.count)
                Spacer()
                Button("Import CSV…") { importCSV() }.disabled(locked)
                Button("Export CSV…") { CSVFiles.export(StepCSV.list(draft.steps), name: "list.csv") }
                if let importError { Text(importError).foregroundStyle(.red).font(.caption) }
            }
            .controlSize(.small)
            Text("One cycle \(ProfileStep.formatSeconds(draft.cycleSeconds)), total \(ProfileStep.formatSeconds(draft.totalSeconds)). The instrument times the steps itself; LoadLab follows the step number about once a second.")
                .font(.caption).foregroundStyle(.secondary)
            DraftBar(dirty: dirty, problems: draft.validate(), sending: sending, disabled: locked, send: send, revert: { draft = session.state.list })
            Divider()
            RunControls(session: session, function: .list, ready: !dirty && draft.validate().isEmpty,
                        confirmText: "Input ON arms the list; LoadLab then triggers it (switching the trigger source to Bus for the run). The input switches off at the end.",
                        stepTotal: session.state.list.steps.count)
        }
        .padding(16)
        .task { if !loaded { await session.loadList(); draft = session.state.list; loaded = true } }
    }

    private var settings: some View {
        HStack(spacing: 18) {
            Picker("Mode", selection: $draft.mode) { ForEach(ListConfig.modes) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented).frame(width: 220)
            Picker("Current", selection: $draft.currentRange) { ForEach(CurrentRange.allCases) { Text($0.label).tag($0) } }
                .frame(width: 140)
            Picker("Voltage", selection: $draft.voltageRange) { ForEach(VoltageRange.allCases) { Text($0.label).tag($0) } }
                .frame(width: 150)
            if draft.mode == .cr {
                Picker("Resistance", selection: $draft.resistanceRange) { ForEach(ResistanceRange.allCases) { Text($0.label).tag($0) } }
                    .frame(width: 220)
            }
            Stepper("Repeat \(draft.count)×", value: $draft.count, in: 1...255)
            Spacer()
        }
        .disabled(locked)
    }

    private var table: some View {
        Table(of: Binding<ListStep>.self, selection: $selection) {
            TableColumn("#") { $s in
                let n = (draft.steps.firstIndex { $0.id == s.id } ?? 0) + 1
                HStack(spacing: 4) {
                    if runningStep == n { Image(systemName: "play.fill").foregroundStyle(.green).font(.caption) }
                    Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(44)
            TableColumn("Level (\(draft.mode.unit))") { $s in CellNumber(value: $s.level, width: 100) }
            TableColumn("Width (s)") { $s in CellNumber(value: $s.width, width: 100) }
            TableColumn("Slew (A/µs)") { $s in
                CellNumber(value: $s.slew, width: 90).disabled(draft.mode != .cc)
            }
        } rows: {
            ForEach($draft.steps) { TableRow($0) }
        }
        .disabled(locked)
        .frame(minHeight: 110)
    }

    private func addStep() {
        let last = draft.steps.last ?? ListStep(level: 0, width: 1)
        draft.steps.append(ListStep(level: last.level, width: last.width, slew: last.slew))
    }

    private func importCSV() {
        importError = nil
        guard let text = CSVFiles.importText() else { return }
        do {
            let steps = try StepCSV.parseList(text)
            guard !steps.isEmpty else { importError = "No steps in that file"; return }
            draft.steps = Array(steps.prefix(SDLLimits.listSteps.upperBound))
        } catch { importError = "\(error)" }
    }

    private func send() {
        sending = true
        Task {
            await session.applyList(draft)
            draft = session.state.list
            sending = false
        }
    }

    /// Compares values (step ids differ between a draft and a read-back).
    private func same(_ a: ListConfig, _ b: ListConfig) -> Bool {
        a.mode == b.mode && a.currentRange == b.currentRange && a.voltageRange == b.voltageRange
            && (a.mode != .cr || a.resistanceRange == b.resistanceRange) && a.count == b.count
            && a.steps.count == b.steps.count && zip(a.steps, b.steps).allSatisfy { $0.sameValues(as: $1) }
    }
}

// MARK: - Program

struct ProgramPane: View {
    @Bindable var session: DeviceSession
    @State private var draft = ProgramConfig()
    @State private var loaded = false
    @State private var sending = false
    @State private var selection: ProgramStep.ID?
    @State private var importError: String?

    private var dirty: Bool {
        draft.stopOnFail != session.state.program.stopOnFail || draft.steps.count != session.state.program.steps.count
            || !zip(draft.steps, session.state.program.steps).allSatisfy { $0.sameValues(as: $1) }
    }
    private var locked: Bool { busy(session) }
    private var results: [Int: ProgramResult] {
        guard let r = session.sequence, r.function == .program else { return [:] }
        return Dictionary(uniqueKeysWithValues: r.programResults.map { ($0.step, $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FunctionBanner(session: session, function: .program)
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    table
                    HStack {
                        Button { addStep() } label: { Label("Add Step", systemImage: "plus") }
                            .disabled(locked || draft.steps.count >= SDLLimits.programSteps.upperBound)
                        Button { if let id = selection { draft.steps.removeAll { $0.id == id }; selection = nil } } label: {
                            Label("Delete", systemImage: "minus")
                        }
                        .disabled(locked || selection == nil || draft.steps.count <= 1)
                        Spacer()
                        Button("Import CSV…") { importCSV() }.disabled(locked)
                        Button("Export CSV…") { CSVFiles.export(StepCSV.program(draft.steps), name: "program.csv") }
                    }
                    .controlSize(.small)
                    if let importError { Text(importError).foregroundStyle(.red).font(.caption) }
                    Toggle("Stop at the first failing step", isOn: $draft.stopOnFail).disabled(locked)
                }
                .padding(.trailing, 8)
                .frame(minWidth: 460, maxHeight: .infinity, alignment: .top)
                inspector.frame(minWidth: 300, idealWidth: 340, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity)
            DraftBar(dirty: dirty, problems: draft.validate(), sending: sending, disabled: locked, send: send,
                     revert: { draft = session.state.program })
            Divider()
            if let r = session.sequence, r.function == .program, r.phase != .running, !r.programResults.isEmpty {
                let failed = r.programResults.filter { !$0.passed }.count
                Label(failed == 0 ? "All \(r.programResults.count) steps passed" : "\(failed) of \(r.programResults.count) steps failed",
                      systemImage: failed == 0 ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.headline).foregroundStyle(failed == 0 ? .green : .red)
            }
            RunControls(session: session, function: .program, ready: !dirty && draft.validate().isEmpty,
                        confirmText: "Input ON arms the program; LoadLab then triggers it (switching the trigger source to Bus for the run). Each step loads for its on-time, is measured after its delay and judged against min/max.",
                        stepTotal: session.state.program.steps.count)
        }
        .padding(16)
        .task { if !loaded { await session.loadProgram(); draft = session.state.program; loaded = true } }
    }

    private var table: some View {
        Table(draft.steps, selection: $selection) {
            TableColumn("#") { s in
                let n = (draft.steps.firstIndex { $0.id == s.id } ?? 0) + 1
                HStack(spacing: 4) {
                    if session.sequence?.function == .program, session.sequence?.phase == .running, session.sequence?.step == n {
                        Image(systemName: "play.fill").foregroundStyle(.green).font(.caption)
                    }
                    Text("\(n)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(40)
            TableColumn("Load") { s in Text(s.short ? "Short" : "\(s.mode.label) \(s.level.formatted()) \(s.mode.unit)") }
            TableColumn("On / off / delay") { s in
                Text("\(s.timeOn.formatted()) / \(s.timeOff.formatted()) / \(s.timeDelay.formatted()) s").monospacedDigit()
            }
            TableColumn("Pass if") { s in
                Text("\(s.min.formatted())–\(s.max.formatted()) \(s.measuredQuantity.unit)").monospacedDigit()
            }
            TableColumn("Result") { s in
                let n = (draft.steps.firstIndex { $0.id == s.id } ?? 0) + 1
                if let r = results[n] {
                    HStack(spacing: 4) {
                        Text("\(r.value.formatted(.number.precision(.fractionLength(4)))) \(r.unit)").monospacedDigit()
                        Text(r.passed ? "PASS" : "FAIL").fontWeight(.semibold).foregroundStyle(r.passed ? .green : .red)
                    }
                } else { Text("—").foregroundStyle(.tertiary) }
            }
        }
        .frame(minHeight: 120, maxHeight: .infinity)
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = selection, let i = draft.steps.firstIndex(where: { $0.id == id }) {
            let st = $draft.steps[i]
            Form {
                Section("Step \(i + 1)") {
                    Picker("Mode", selection: st.mode) { ForEach(LoadMode.allCases) { Text($0.label).tag($0) } }
                    Toggle("Short circuit", isOn: st.short)
                    if !st.wrappedValue.short {
                        if st.wrappedValue.mode == .led {
                            NumberRow(label: "Vo", value: st.level, unit: "V")
                            NumberRow(label: "Io", value: st.ledCurrent, unit: "A")
                            NumberRow(label: "Rco", value: st.ledRco, unit: "")
                        } else {
                            NumberRow(label: "Level", value: st.level, unit: st.wrappedValue.mode.unit)
                        }
                    }
                    Picker("Current range", selection: st.currentRange) { ForEach(CurrentRange.allCases) { Text($0.label).tag($0) } }
                    Picker("Voltage range", selection: st.voltageRange) { ForEach(VoltageRange.allCases) { Text($0.label).tag($0) } }
                    if st.wrappedValue.mode == .cr {
                        Picker("Resistance range", selection: st.resistanceRange) { ForEach(ResistanceRange.allCases) { Text($0.label).tag($0) } }
                    }
                }
                Section("Timing") {
                    NumberRow(label: "On", value: st.timeOn, unit: "s")
                    NumberRow(label: "Off", value: st.timeOff, unit: "s")
                    NumberRow(label: "Measure after", value: st.timeDelay, unit: "s")
                    Toggle("Pause before this step", isOn: st.pause)
                }
                Section {
                    NumberRow(label: "Min", value: st.min, unit: st.wrappedValue.measuredQuantity.unit)
                    NumberRow(label: "Max", value: st.max, unit: st.wrappedValue.measuredQuantity.unit)
                } header: {
                    Text("Pass window (\(st.wrappedValue.measuredQuantity.name.lowercased()))")
                } footer: {
                    Text("The instrument measures \(st.wrappedValue.mode == .cv ? "current (CV steps)" : "voltage (current for CV steps)") after the delay.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(locked)
        } else {
            ContentUnavailableView("Select a step", systemImage: "checklist", description: Text("Its settings appear here."))
        }
    }

    private func addStep() {
        var s = draft.steps.last ?? ProgramStep()
        s.id = UUID()
        draft.steps.append(s)
        selection = s.id
    }

    private func importCSV() {
        importError = nil
        guard let text = CSVFiles.importText() else { return }
        do {
            let steps = try StepCSV.parseProgram(text)
            guard !steps.isEmpty else { importError = "No steps in that file"; return }
            draft.steps = Array(steps.prefix(SDLLimits.programSteps.upperBound))
        } catch { importError = "\(error)" }
    }

    private func send() {
        sending = true
        Task {
            await session.applyProgram(draft)
            draft = session.state.program
            sending = false
        }
    }
}

// MARK: - OCPT / OPPT

struct ProtectionTestPane: View {
    @Bindable var session: DeviceSession
    @State private var kind: ActiveFunction = .ocpt
    @State private var draft = ProtectionTestConfig()
    @State private var loadedKind: ActiveFunction?
    @State private var sending = false

    private var isPower: Bool { kind == .oppt }
    private var unit: String { isPower ? "W" : "A" }
    private var saved: ProtectionTestConfig { isPower ? session.state.oppt : session.state.ocpt }
    private var dirty: Bool { draft != saved }
    private var locked: Bool { busy(session) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Test", selection: $kind) {
                    Text("Over-current (OCPT)").tag(ActiveFunction.ocpt)
                    Text("Over-power (OPPT)").tag(ActiveFunction.oppt)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                .disabled(locked)
                FunctionBanner(session: session, function: kind, title: isPower ? "OPPT" : "OCPT")
                Text(isPower
                     ? "Raises the load power from Start by Step every Step delay until the source's voltage falls below the trip voltage (its over-power protection acted) or End is reached. Passes if the trip power is inside the window."
                     : "Raises the load current from Start by Step every Step delay until the source's voltage falls below the trip voltage (its over-current protection acted) or End is reached. Passes if the trip current is inside the window.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                form
                DraftBar(dirty: dirty, problems: draft.validate(isPower: isPower), sending: sending, disabled: locked,
                         send: send, revert: { draft = saved })
                Divider()
                result
                RunControls(session: session, function: kind, ready: !dirty && draft.validate(isPower: isPower).isEmpty,
                            confirmText: "Input ON starts the ramp immediately: up to \(draft.end.formatted()) \(unit) over at most \(ProfileStep.formatSeconds(draft.maxSeconds)). LoadLab samples quickly to find the trip point (the instrument doesn't report it).")
            }
            .padding(16)
        }
        .task(id: kind) {
            if session.state.function == .oppt { if loadedKind == nil { kind = .oppt } }
            await session.loadProtectionTest(kind)
            draft = saved
            loadedKind = kind
        }
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Ranges")
                Picker("Current", selection: $draft.currentRange) { ForEach(CurrentRange.allCases) { Text($0.label).tag($0) } }.frame(width: 150)
                Picker("Voltage", selection: $draft.voltageRange) { ForEach(VoltageRange.allCases) { Text($0.label).tag($0) } }.frame(width: 150)
            }
            GridRow {
                Text("Ramp")
                field("Start", $draft.start, unit)
                field("Step", $draft.step, unit)
                field("Step delay", $draft.stepDelay, "s")
                field("End", $draft.end, unit)
            }
            GridRow {
                Text("Trip when V <")
                field("", $draft.voltage, "V")
            }
            GridRow {
                Text("Pass window")
                field("Min", $draft.min, unit)
                field("Max", $draft.max, unit)
            }
        }
        .disabled(locked)
    }

    private func field(_ label: String, _ v: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 4) {
            if !label.isEmpty { Text(label).foregroundStyle(.secondary) }
            CellNumber(value: v, width: 80)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var result: some View {
        if let r = session.sequence, r.function == kind {
            VStack(alignment: .leading, spacing: 8) {
                if let res = r.protectionResult {
                    HStack(spacing: 10) {
                        Image(systemName: res.passed ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(res.passed ? .green : .red).font(.title2)
                        VStack(alignment: .leading) {
                            Text(res.summary).font(.headline)
                            Text("\(res.passed ? "PASS" : "FAIL") · window \(res.min.formatted())–\(res.max.formatted()) \(res.unit) · estimated from \(r.trace.count) fast readings")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let note = r.note {
                    Label(note, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if r.trace.count > 1 {
                    let t0 = r.trace[0].date
                    let pts = r.trace.map { (t: $0.date.timeIntervalSince(t0), v: $0.voltage, load: isPower ? $0.power : $0.current) }
                    VStack(spacing: 6) {
                        Chart {
                            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                                LineMark(x: .value("s", p.t), y: .value(unit, p.load)).foregroundStyle(Color.orange)
                            }
                        }
                        .chartYAxisLabel(isPower ? "Power (W)" : "Current (A)")
                        .frame(height: 120)
                        Chart {
                            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                                LineMark(x: .value("s", p.t), y: .value("V", p.v)).foregroundStyle(Color.blue)
                            }
                            RuleMark(y: .value("Trip", draft.voltage)).foregroundStyle(.red.opacity(0.5)).lineStyle(StrokeStyle(dash: [4, 4]))
                        }
                        .chartYAxisLabel("Voltage (V)")
                        .chartXAxisLabel("Time (s)")
                        .frame(height: 120)
                    }
                }
            }
        }
    }

    private func send() {
        sending = true
        Task {
            await session.applyProtectionTest(kind, draft)
            draft = saved
            sending = false
        }
    }
}

// MARK: - Ext

struct ExtPane: View {
    @Bindable var session: DeviceSession

    var body: some View {
        Form {
            Section {
                Picker("Control", selection: Binding(get: { session.state.externalMode },
                                                     set: { m in Task { await session.setExternal(mode: m) } })) {
                    Text("Off (internal)").tag(ExternalMode.internalControl)
                    Text("External current (CC)").tag(ExternalMode.externalCurrent)
                    Text("External voltage (CV)").tag(ExternalMode.externalVoltage)
                }
                .pickerStyle(.radioGroup)
                Picker("Current range", selection: Binding(get: { session.state.extCurrentRange },
                                                           set: { r in Task { await session.setExternal(currentRange: r) } })) {
                    ForEach(CurrentRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Voltage range", selection: Binding(get: { session.state.extVoltageRange },
                                                           set: { r in Task { await session.setExternal(voltageRange: r) } })) {
                    ForEach(VoltageRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("External analog control")
            } footer: {
                Text("A 0–10 V signal on the rear-panel terminals sets the load level across the selected range (per the user manual). Changing the control mode switches the input off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rear-panel signals") {
                LabeledContent("Control voltage") {
                    Text(session.state.extControlVoltage.map { "\($0.formatted(.number.precision(.fractionLength(4)))) V" } ?? "—")
                        .monospacedDigit()
                }
                Toggle("Rear-panel input on/off control", isOn: Binding(get: { session.state.extInputSwitch },
                                                                         set: { v in Task { await session.setExtInputSwitch(v) } }))
            }
            if session.state.externalMode != .internalControl {
                Section {
                    Label("With the input on, the load follows the control voltage. If nothing drives the control input, check what the instrument does before connecting a source.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(busy(session))
        .task {
            // Follow the control voltage while this screen is open.
            while !Task.isCancelled {
                await session.refreshExtControlVoltage()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
