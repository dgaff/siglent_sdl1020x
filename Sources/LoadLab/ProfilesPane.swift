import SwiftUI
import AppKit
import LoadLabCore
import SDLKit

/// App-scripted discharge profiles: edit, save, run. Editing works without a connection.
struct ProfilesPane: View {
    let session: DeviceSession?

    var body: some View {
        if let s = session, let r = s.recorder, r.info.kind == "profile" {
            RunDashboard(session: s, recorder: r)
        } else {
            ProfileEditor(session: session)
        }
    }
}

private struct ProfileEditor: View {
    let session: DeviceSession?

    @State private var store = ProfileStore()
    @State private var profiles: [Profile] = []
    @State private var selectedID: UUID?
    @State private var draft: Profile?
    @State private var selectedStep: UUID?
    @State private var cell = CellInfo()
    @State private var confirming = false
    @State private var starting = false
    @State private var startError: String?
    @State private var loaded = false

    @AppStorage("profiles.lastCell") private var savedCell: Data = Data()
    @AppStorage("profiles.lastSelected") private var lastSelected: String = ""

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
            Group {
                if draft != nil {
                    editor
                } else {
                    ContentUnavailableView {
                        Label("No profile selected", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("Create one from a template with the + menu.")
                    }
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: load)
        .onChange(of: selectedID) { _, id in
            draft = profiles.first { $0.id == id }
            selectedStep = nil
            startError = nil
            lastSelected = id?.uuidString ?? ""
        }
        .onChange(of: draft) { _, d in
            guard var d, let i = profiles.firstIndex(where: { $0.id == d.id }), profiles[i] != d else { return }
            d.modified = Date()
            profiles[i] = d
            try? store.save(d)
        }
        .onChange(of: cell) { _, c in savedCell = (try? JSONEncoder().encode(c)) ?? Data() }
    }

    // MARK: Profile list

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(profiles) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).lineLimit(1)
                        Text("\(p.allSteps.count) step\(p.allSteps.count == 1 ? "" : "s") · cut-off \(p.limits.cutoffVoltage.formatted()) V")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(p.id)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Menu {
                    Section("From a template (sized for the cell below)") {
                        ForEach(ProfileTemplate.allCases) { t in
                            Button(t.title) { add(t.make(cell: cell, maxCurrent: defaultMaxCurrent)) }
                        }
                    }
                    Button("Blank profile") {
                        var p = Profile(name: "New profile", steps: [.hold(.cc, 0.5)])
                        p.limits.cutoffVoltage = cell.suggestedCutoff ?? 3.0
                        add(p)
                    }
                } label: { Image(systemName: "plus") }
                .menuIndicator(.hidden).fixedSize()
                .help("New profile")
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                    .disabled(draft == nil).help("Duplicate")
                Button { deleteSelected() } label: { Image(systemName: "trash") }
                    .disabled(draft == nil).help("Move to Trash")
                Spacer()
                Button { NSWorkspace.shared.open(store.root) } label: { Image(systemName: "folder") }
                    .help("Show profile files")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    /// The bench rule for this rig is < 1 A; templates default under that.
    private var defaultMaxCurrent: Double { 0.9 }

    // MARK: Editor

    private var binding: Binding<Profile> {
        Binding(get: { draft ?? Profile(name: "", steps: []) }, set: { draft = $0 })
    }

    private var editor: some View {
        let p = binding
        return Form {
            Section("Profile") {
                TextField("Name", text: p.name)
                TextField("Notes", text: p.notes, axis: .vertical).lineLimit(1...4)
            }
            stepsSection
            if let id = selectedStep, p.wrappedValue.step(id) != nil {
                Section("Selected step") {
                    StepInspector(step: Binding(
                        get: { p.wrappedValue.step(id) ?? ProfileStep(kind: .mark) },
                        set: { p.wrappedValue.update($0) }))
                }
            }
            safetySection
            cellSection
            startSection
        }
        .formStyle(.grouped)
        .confirmationDialog("Start profile?", isPresented: $confirming) {
            Button("Start (input ON)") { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmText)
        }
    }

    private var stepsSection: some View {
        let p = binding
        let rows = p.wrappedValue.rows
        return Section {
            if rows.isEmpty {
                Text("No steps yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.step.id) { index, row in
                Button {
                    selectedStep = selectedStep == row.step.id ? nil : row.step.id
                } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                        Image(systemName: row.step.kind.symbol).frame(width: 18).foregroundStyle(.secondary)
                        Text(row.step.kind.label).fontWeight(.medium)
                        Text(row.step.summary).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, CGFloat(row.depth) * 22)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                    .background(selectedStep == row.step.id ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                Menu("Add Step") {
                    ForEach(ProfileStep.Kind.allCases) { k in
                        Button { addStep(k, inside: false) } label: { Label(k.label, systemImage: k.symbol) }
                    }
                }
                .fixedSize()
                if let id = selectedStep, p.wrappedValue.step(id)?.kind == .loop {
                    Menu("Add Inside Repeat") {
                        ForEach(ProfileStep.Kind.allCases.filter { $0 != .loop }) { k in
                            Button { addStep(k, inside: true) } label: { Label(k.label, systemImage: k.symbol) }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Group {
                    Button { if let id = selectedStep { p.wrappedValue.move(id, by: -1) } } label: { Image(systemName: "arrow.up") }
                        .help("Move up")
                    Button { if let id = selectedStep { p.wrappedValue.move(id, by: 1) } } label: { Image(systemName: "arrow.down") }
                        .help("Move down")
                    Button(role: .destructive) {
                        if let id = selectedStep { p.wrappedValue.remove(id); selectedStep = nil }
                    } label: { Image(systemName: "trash") }
                        .help("Delete step")
                }
                .disabled(selectedStep == nil)
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Click a step to edit it. Every step also ends when the cut-off voltage is reached under load, which ends the whole profile.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var safetySection: some View {
        let p = binding
        return Section {
            NumberRow(label: "Cut-off voltage", value: p.limits.cutoffVoltage, unit: "V")
            if let s = cell.suggestedCutoff, abs(s - p.wrappedValue.limits.cutoffVoltage) > 0.001 {
                Button("Use \(s.formatted()) V (typical for \(cell.seriesCells)× \(cell.chemistry))") { p.wrappedValue.limits.cutoffVoltage = s }
                    .buttonStyle(.link).font(.caption)
            }
            NumberRow(label: "Maximum current", value: p.limits.maxCurrent, unit: "A")
            OptionalNumberRow(label: "Stop after capacity", value: p.limits.maxCapacity_mAh, unit: "mAh")
            OptionalNumberRow(label: "Stop after time",
                              value: Binding(get: { p.wrappedValue.limits.maxDuration_s.map { $0 / 60 } },
                                             set: { p.wrappedValue.limits.maxDuration_s = $0.map { $0 * 60 } }),
                              unit: "min")
            NumberRow(label: "Von margin below cut-off", value: p.limits.hardwareMargin, unit: "V")
            Picker("Current range", selection: p.currentRange) { ForEach(CurrentRange.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            Picker("Voltage range", selection: p.voltageRange) { ForEach(VoltageRange.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.segmented)
            if p.wrappedValue.modesUsed.contains(.cr) {
                Picker("Resistance range", selection: p.resistanceRange) { ForEach(ResistanceRange.allCases) { Text($0.label).tag($0) } }
            }
            Picker("Sample rate", selection: p.sampleRateHz) {
                ForEach([0.5, 1, 2, 5, 10], id: \.self) { hz in Text(hz < 1 ? "every 2 s" : "\(Int(hz)) per second").tag(hz) }
            }
        } header: {
            Text("Safety and recording")
        } footer: {
            Text("LoadLab checks every reading against these limits and switches the input off if one is crossed. The instrument's Von is set to \(max(0, p.wrappedValue.limits.cutoffVoltage - p.wrappedValue.limits.hardwareMargin).formatted()) V with latch off for the run, so it stops sinking by itself if the Mac sleeps or the network drops. The Mac is kept awake, and your Basic and Von settings are restored afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cellSection: some View {
        Section("Cell / pack") {
            TextField("Name", text: $cell.name, prompt: Text("e.g. Samsung 30Q #3"))
            Picker("Chemistry", selection: $cell.chemistry) { ForEach(CellInfo.chemistries, id: \.self) { Text($0) } }
            Stepper("Cells in series: \(cell.seriesCells)", value: $cell.seriesCells, in: 1...48)
            OptionalNumberRow(label: "Nominal capacity", value: $cell.nominalCapacity_mAh, unit: "mAh")
            OptionalNumberRow(label: "Nominal voltage", value: $cell.nominalVoltage, unit: "V")
            OptionalNumberRow(label: "Temperature", value: $cell.temperatureC, unit: "°C")
        }
    }

    private var problems: [String] { draft?.validate() ?? [] }

    private var startSection: some View {
        Section {
            ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let e = startError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            HStack {
                if let d = draft {
                    if let est = d.estimatedDuration(capacity_mAh: cell.nominalCapacity_mAh) {
                        Text("About \(ProfileStep.formatSeconds(est))").foregroundStyle(.secondary)
                    } else {
                        Text("Runs until the cut-off").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if session == nil {
                    Text("Connect an instrument to run").foregroundStyle(.secondary)
                }
                Button { confirming = true } label: {
                    Label(starting ? "Starting…" : "Start Profile", systemImage: "play.fill").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStart)
            }
        }
    }

    private var canStart: Bool {
        guard let s = session, s.link.isUsable, !starting, draft != nil, problems.isEmpty else { return false }
        return s.recorder?.isActive != true
    }

    private var confirmText: String {
        guard let d = draft else { return "" }
        return "\(d.name) on \(cell.name.isEmpty ? "the connected cell" : cell.name): \(d.allSteps.count) steps, cut-off \(d.limits.cutoffVoltage.formatted()) V, max \(d.limits.maxCurrent.formatted()) A. The instrument switches to Basic and the input turns ON."
    }

    // MARK: Actions

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let c = try? JSONDecoder().decode(CellInfo.self, from: savedCell) { cell = c }
        profiles = store.all()
        if profiles.isEmpty {
            // First visit: one of each template to start from.
            for t in ProfileTemplate.allCases {
                let p = t.make(cell: cell, maxCurrent: defaultMaxCurrent)
                try? store.save(p)
            }
            profiles = store.all()
        }
        selectedID = profiles.first { $0.id.uuidString == lastSelected }?.id ?? profiles.first?.id
        draft = profiles.first { $0.id == selectedID }
    }

    private func add(_ p: Profile) {
        try? store.save(p)
        profiles = store.all()
        selectedID = p.id
    }

    private func duplicate() {
        guard var p = draft else { return }
        p.id = UUID()
        p.name += " copy"
        for i in p.steps.indices { p.steps[i] = Self.reID(p.steps[i]) }
        add(p)
    }

    private static func reID(_ s: ProfileStep) -> ProfileStep {
        var c = s
        c.id = UUID()
        c.children = s.children.map(reID)
        return c
    }

    private func deleteSelected() {
        guard let p = draft else { return }
        try? store.delete(p)
        profiles = store.all()
        selectedID = profiles.first?.id
    }

    private func addStep(_ kind: ProfileStep.Kind, inside: Bool) {
        guard var p = draft else { return }
        var s = ProfileStep(kind: kind)
        let base = min(0.5, p.limits.maxCurrent)
        switch kind {
        case .hold: s.level = base
        case .rest: s.duration = 60
        case .pulse: s.level = base; s.duration = 2; s.level2 = base / 5; s.duration2 = 8; s.count = 10
        case .dcr: s.level = base / 5; s.duration = 10; s.level2 = base; s.duration2 = 2
        case .loop: s.count = 5
        case .mark: s.label = "Mark"
        }
        if inside, let id = selectedStep { p.append(s, into: id) } else { p.insert(s, after: selectedStep) }
        draft = p
        selectedStep = s.id
    }

    private func start() {
        guard let s = session, let p = draft else { return }
        startError = nil
        starting = true
        Task {
            do { try await s.startProfileRun(p, cell: cell) }
            catch { startError = "\(error)" }
            starting = false
        }
    }
}

/// Fields for one step; which ones show depends on the kind.
private struct StepInspector: View {
    @Binding var step: ProfileStep

    var body: some View {
        LabeledContent("Type") {
            Label(step.kind.label, systemImage: step.kind.symbol)
        }
        switch step.kind {
        case .hold:
            modePicker
            NumberRow(label: "Level", value: $step.level, unit: step.mode.unit)
            OptionalNumberRow(label: "End after", value: $step.duration, unit: "s")
            OptionalNumberRow(label: "End after delivering", value: $step.untilCapacity, unit: "mAh")
            OptionalNumberRow(label: "End when voltage ≤", value: $step.untilVoltage, unit: "V")
            Text("Leave all three empty to hold until the profile's cut-off.").font(.caption).foregroundStyle(.secondary)
        case .rest:
            NumberRow(label: "Input off for", value: optional($step.duration), unit: "s")
        case .pulse:
            modePicker
            NumberRow(label: "Pulse level", value: $step.level, unit: step.mode.unit)
            NumberRow(label: "Pulse length", value: optional($step.duration), unit: "s")
            NumberRow(label: "Base level", value: $step.level2, unit: step.mode.unit)
            NumberRow(label: "Base length", value: optional($step.duration2), unit: "s")
            Stepper("Pulses: \(step.count ?? 0)", value: Binding(get: { step.count ?? 1 }, set: { step.count = $0 }), in: 1...10_000)
        case .dcr:
            NumberRow(label: "Current 1", value: $step.level, unit: "A")
            NumberRow(label: "Hold for", value: optional($step.duration), unit: "s")
            NumberRow(label: "Current 2", value: $step.level2, unit: "A")
            NumberRow(label: "Hold for", value: optional($step.duration2), unit: "s")
            Text("Resistance = ΔV / ΔI between the readings at the end of each current.").font(.caption).foregroundStyle(.secondary)
        case .loop:
            OptionalNumberRow(label: "Repeat at most", value: Binding(get: { step.count.map(Double.init) },
                                                                     set: { step.count = $0.map { max(1, Int($0)) } }), unit: "times")
            OptionalNumberRow(label: "Until run total", value: $step.untilCapacity, unit: "mAh")
            OptionalNumberRow(label: "Until voltage ≤", value: $step.untilVoltage, unit: "V")
            Text("Checked after each pass. The cut-off also ends the repeat (and the profile).").font(.caption).foregroundStyle(.secondary)
        case .mark:
            TextField("Label", text: $step.label)
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $step.mode) { ForEach(StepMode.allCases) { Text($0.label).tag($0) } }
            .pickerStyle(.segmented)
    }

    private func optional(_ b: Binding<Double?>) -> Binding<Double> {
        Binding(get: { b.wrappedValue ?? 0 }, set: { b.wrappedValue = $0 })
    }
}
