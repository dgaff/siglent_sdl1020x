import SwiftUI
import LoadLabCore
import SDLKit

/// Always-visible strip: live V/A/W/Ω, input switch, short, trigger, and a status line that
/// mirrors EasySDL's bottom bar.
struct ReadoutBar: View {
    @Bindable var session: DeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) {
                    tiles
                    Spacer(minLength: 12)
                    controls
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 20) { tiles }
                    controls
                }
            }
            statusLine
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var tiles: some View {
        ReadoutTile(quantity: .voltage, value: session.latest?.voltage)
        ReadoutTile(quantity: .current, value: session.latest?.current)
        ReadoutTile(quantity: .power, value: session.latest?.power)
        ReadoutTile(quantity: .resistance, value: session.latest?.resistance)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Task { await session.setShort(!session.state.shortOn) }
            } label: {
                Label("Short", systemImage: "bolt.horizontal")
            }
            .tint(session.state.shortOn ? .red : nil)
            .disabled(!session.link.isUsable || session.state.function != .basic)
            .help("Short circuit the input (Basic function only)")

            Button {
                Task { await session.trigger() }
            } label: {
                Label("Trigger", systemImage: "scope")
            }
            .disabled(!session.link.isUsable || session.state.triggerSource != .bus)
            .help(session.state.triggerSource == .bus
                  ? "Send a bus trigger (*TRG)"
                  : "The trigger source is \(session.state.triggerSource.label): the instrument ignores remote triggers. Change it to Bus in Instrument Settings, or use the front-panel Trigger key. (List and Program runs started from LoadLab switch to Bus for the run.)")

            InputSwitch(on: session.state.inputOn, enabled: session.link.isUsable) {
                Task { await session.setInput(!session.state.inputOn) }
            }
        }
        .controlSize(.large)
    }

    private var statusLine: some View {
        let s = session.state
        return HStack(spacing: 6) {
            Circle().fill(linkColor).frame(width: 8, height: 8)
            Text(session.identity.map { "\($0.model) · \(session.host)" } ?? session.host)
                .font(.caption).foregroundStyle(.secondary)
            if case .reconnecting = session.link { StatusChip(text: session.link.label, tint: .orange) }
            Divider().frame(height: 12)
            StatusChip(text: s.function.label + (s.function == .basic ? " · \(s.mode.label)\(s.dynamic ? " DYN" : "")" : ""))
            StatusChip(text: "Trig: \(s.triggerSource.label)", on: false)
            StatusChip(text: "Avg 2^\(s.averageExponent)", on: false)
            StatusChip(text: "Sense", on: s.sense)
            StatusChip(text: "Von \(s.vOn.formatted(.number.precision(.fractionLength(2)))) V\(s.vOnLatch ? " latch" : "")", on: s.vOn > 0)
            StatusChip(text: "I-Prot", on: s.currentProtection.enabled, tint: .orange)
            StatusChip(text: "P-Prot", on: s.powerProtection.enabled, tint: .orange)
            StatusChip(text: "SoF", on: s.stopOnFail)
            Spacer()
            if let err = session.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1).truncationMode(.middle)
                    .onTapGesture { session.lastError = nil }
                    .help(err + " — click to dismiss")
            }
        }
    }

    private var linkColor: Color {
        switch session.link {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected: .gray
        case .failed: .red
        }
    }
}

/// The big ON/OFF control. Red when the load is sinking.
struct InputSwitch: View {
    let on: Bool
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "power")
                Text(on ? "INPUT ON" : "INPUT OFF").monospaced()
            }
            .font(.headline)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minWidth: 130)
        }
        .buttonStyle(.borderedProminent)
        .tint(on ? .red : .gray)
        .disabled(!enabled)
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .help("Toggle the load input (⇧⌘I). Emergency off: ⌘.")
    }
}
