import SwiftUI
import LoadLabCore
import SDLKit

/// Basic function: CC/CV/CP/CR/LED, static or dynamic (EasySDL's "Basic" screen).
struct BasicPane: View {
    @Bindable var session: DeviceSession

    private var s: DeviceState { session.state }
    private var mode: LoadMode { s.mode }
    private var config: ModeConfig { s[mode: mode] }
    private var usable: Bool { session.link.isUsable && s.function == .basic }

    var body: some View {
        Form {
            if s.function != .basic {
                Section {
                    HStack {
                        Label("The instrument is running the \(s.function.label) function.", systemImage: "info.circle")
                        Spacer()
                        Button("Switch to Basic") { Task { await session.switchToBasic() } }
                    }
                }
            }

            Group {
            Section {
                Picker("Mode", selection: Binding(get: { mode }, set: { m in Task { await session.setMode(m) } })) {
                    ForEach(LoadMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Dynamic (transient) operation", isOn: Binding(
                    get: { s.dynamic },
                    set: { on in Task { await session.setDynamic(on) } }))
                    .disabled(mode == .led)
                    .help("Alternate between level A and B. The SDL can't report this state, so LoadLab tracks it; it resets to static after reconnecting.")
                if mode.changesTurnInputOff {
                    Text("Changing mode or static/dynamic switches the input off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Ranges") {
                Picker("Current range", selection: Binding(
                    get: { s.activeCurrentRange },
                    set: { r in Task { await session.setCurrentRange(mode, r) } })) {
                    ForEach(CurrentRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Voltage range", selection: Binding(
                    get: { s.activeVoltageRange },
                    set: { r in Task { await session.setVoltageRange(mode, r) } })) {
                    ForEach(VoltageRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if mode == .cr {
                    Picker("Resistance range", selection: Binding(
                        get: { s.resistanceRange },
                        set: { r in Task { await session.setResistanceRange(r) } })) {
                        ForEach(ResistanceRange.allCases) { Text($0.label).tag($0) }
                    }
                }
            }

            if mode == .led {
                Section("LED") {
                    NumericField(label: "Vo (forward voltage)", value: s.ledVoltage, unit: "V") { await session.setLED(.voltage, $0) }
                    NumericField(label: "Io (current)", value: s.ledCurrent, unit: "A") { await session.setLED(.current, $0) }
                    NumericField(label: "Rco (coefficient)", value: s.ledRco, unit: "") { await session.setLED(.rco, $0) }
                }
            } else if s.dynamic {
                dynamicSection
            } else {
                Section("Setpoint") {
                    NumericField(label: mode.levelLabel, value: config.level, unit: mode.unit,
                                 digits: mode == .cr ? 3 : 3,
                                 range: SDLLimits.level(mode, currentRange: config.currentRange, voltageRange: config.voltageRange)) {
                        await session.setLevel(mode, $0)
                    }
                    if mode == .cc { slewFields }
                }
            }
            }
            .disabled(!usable)
        }
        .formStyle(.grouped)
    }

    private var slewFields: some View {
        Group {
            let r = SDLLimits.slew(s.activeCurrentRange)
            NumericField(label: "Slew rise", value: s.dynamic ? s.transientSlewRise : s.slewRise, unit: "A/µs", range: r) {
                await session.setSlew(.rise, $0)
            }
            NumericField(label: "Slew fall", value: s.dynamic ? s.transientSlewFall : s.slewFall, unit: "A/µs", range: r) {
                await session.setSlew(.fall, $0)
            }
        }
    }

    private var dynamicSection: some View {
        Section("Dynamic") {
            Picker("Waveform", selection: Binding(
                get: { config.transientMode },
                set: { t in Task { await session.setTransientMode(mode, t) } })) {
                ForEach(TransientMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(config.transientMode.explanation).font(.caption).foregroundStyle(.secondary)
            let lr = SDLLimits.level(mode, currentRange: config.transientCurrentRange, voltageRange: config.transientVoltageRange)
            let wr = SDLLimits.transientWidth(mode)
            NumericField(label: "Level A", value: config.aLevel, unit: mode.unit, range: lr) { await session.setTransient(mode, .aLevel, $0) }
            NumericField(label: "Level B", value: config.bLevel, unit: mode.unit, range: lr) { await session.setTransient(mode, .bLevel, $0) }
            if config.transientMode != .toggle {
                NumericField(label: "Width A", value: config.aWidth, unit: "s", digits: 5, range: wr) { await session.setTransient(mode, .aWidth, $0) }
                NumericField(label: "Width B", value: config.bWidth, unit: "s", digits: 5, range: wr) { await session.setTransient(mode, .bWidth, $0) }
            }
            if mode == .cc { slewFields }
        }
    }
}

extension LoadMode {
    var levelLabel: String {
        switch self {
        case .cc: "Current"
        case .cv: "Voltage"
        case .cp: "Power"
        case .cr: "Resistance"
        case .led: "Voltage"
        }
    }
    var changesTurnInputOff: Bool { true }
}

extension TransientMode {
    var explanation: String {
        switch self {
        case .continuous: "Alternates A → B continuously."
        case .pulse: "Each trigger switches to B for Width B, then returns to A."
        case .toggle: "Each trigger toggles between A and B."
        }
    }
}
