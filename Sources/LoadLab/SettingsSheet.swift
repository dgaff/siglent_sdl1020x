import SwiftUI
import LoadLabCore
import SDLKit

/// Instrument-wide settings (EasySDL's Utility menu / status bar items).
struct SettingsSheet: View {
    @Bindable var session: DeviceSession
    @Environment(\.dismiss) private var dismiss

    private var s: DeviceState { session.state }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Measurement") {
                    Toggle("Remote sense (4-wire)", isOn: Binding(get: { s.sense }, set: { v in Task { await session.setSense(v) } }))
                        .help("Measure voltage at the sense terminals. Wire the rear sense inputs first.")
                    Picker("Averaging", selection: Binding(get: { s.averageExponent }, set: { v in Task { await session.setAverageExponent(v) } })) {
                        ForEach(Array(SDLLimits.averageExponent), id: \.self) { n in Text("2^\(n) (\(1 << n) points)").tag(n) }
                    }
                }
                Section("Break-over voltage (Von)") {
                    NumericField(label: "Von", value: s.vOn, unit: "V", range: SDLLimits.vOn) { await session.setVOn($0) }
                    Toggle("Von latch", isOn: Binding(get: { s.vOnLatch }, set: { v in Task { await session.setVOnLatch(v) } }))
                    Text("The load only sinks while the input is above Von. With latch off it stops again when the voltage falls below Von. That's the hardware under-voltage cutoff LoadLab will use for battery safety.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Software protection") {
                    ProtectionEditor(title: "Current", unit: "A", config: s.currentProtection) { await session.setProtection(.current, $0) }
                    ProtectionEditor(title: "Power", unit: "W", config: s.powerProtection) { await session.setProtection(.power, $0) }
                }
                Section("Trigger & sequencing") {
                    Picker("Trigger source", selection: Binding(get: { s.triggerSource }, set: { v in Task { await session.setTriggerSource(v) } })) {
                        ForEach(TriggerSource.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Stop Program on fail (SoF)", isOn: Binding(get: { s.stopOnFail }, set: { v in Task { await session.setStopOnFail(v) } }))
                }
                Section("Rear-panel monitor outputs") {
                    Toggle("Current monitor (IMON)", isOn: Binding(get: { s.currentMonitor }, set: { v in Task { await session.setMonitors(current: v, voltage: s.voltageMonitor) } }))
                    Toggle("Voltage monitor (VMON)", isOn: Binding(get: { s.voltageMonitor }, set: { v in Task { await session.setMonitors(current: s.currentMonitor, voltage: v) } }))
                }
                if let id = session.identity {
                    Section("Instrument") {
                        LabeledContent("Model", value: id.model)
                        LabeledContent("Serial", value: id.serial)
                        LabeledContent("Firmware", value: id.firmware)
                        LabeledContent("Address", value: "\(session.host):\(session.port)")
                    }
                }
            }
            .formStyle(.grouped)
            if let err = session.lastError {
                Text(err).font(.caption).foregroundStyle(.orange).padding(.horizontal)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 640)
    }
}

private struct ProtectionEditor: View {
    let title: String
    let unit: String
    let config: ProtectionConfig
    let apply: (ProtectionConfig) async -> Void

    var body: some View {
        Toggle("\(title) protection", isOn: Binding(get: { config.enabled }, set: { v in
            var c = config; c.enabled = v; Task { await apply(c) }
        }))
        NumericField(label: "\(title) limit", value: config.level, unit: unit) { v in
            var c = config; c.level = v; await apply(c)
        }
        NumericField(label: "Delay", value: config.delay, unit: "s") { v in
            var c = config; c.delay = v; await apply(c)
        }
    }
}
