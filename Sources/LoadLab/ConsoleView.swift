import SwiftUI
import LoadLabCore
import SCPIKit

/// Raw SCPI console + command log (debug window).
struct ConsoleView: View {
    let app: AppModel
    @State private var command = ""
    @State private var output: [String] = []
    @State private var hidePolling = true

    var body: some View {
        if let session = app.session {
            VStack(spacing: 0) {
                HStack {
                    Toggle("Hide polling", isOn: $hidePolling).toggleStyle(.checkbox)
                    Spacer()
                    Button("Clear") { session.clearLog(); output.removeAll() }
                }
                .padding(8)
                Divider()
                ScrollViewReader { proxy in
                    List {
                        ForEach(filtered(session.log)) { e in
                            HStack(alignment: .top, spacing: 8) {
                                Text(e.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                                    .foregroundStyle(.tertiary)
                                Text(prefix(e.kind)).foregroundStyle(color(e.kind)).frame(width: 18)
                                Text(e.text).textSelection(.enabled)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .id(e.id)
                        }
                    }
                    .onChange(of: session.log.count) { _, _ in
                        if let last = filtered(session.log).last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                Divider()
                ForEach(output.suffix(3), id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8) }
                HStack {
                    TextField("SCPI command, e.g. :CURR? or MEAS:VOLT?", text: $command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(send)
                    Button("Send", action: send).disabled(command.isEmpty)
                }
                .padding(8)
            }
        } else {
            ContentUnavailableView("Not connected", systemImage: "terminal")
        }
    }

    private func send() {
        let c = command
        command = ""
        Task {
            let r = await app.session?.raw(c) ?? "Not connected"
            output.append("\(c) → \(r)")
        }
    }

    private func filtered(_ log: [SCPILogEntry]) -> [SCPILogEntry] {
        guard hidePolling else { return log }
        let noisy = ["MEAS:", ":INP?", ":SHOR?", ":BATT:FUNC?", ":LIST:STAT?", ":PROG:STAT?", ":OCP:FUNC?", ":OPP:FUNC?", "EXT:MODE?"]
        var out: [SCPILogEntry] = []
        var skipReply = false
        for e in log {
            switch e.kind {
            case .query where noisy.contains { e.text.hasPrefix($0) }: skipReply = true
            case .reply where skipReply: skipReply = false
            default: skipReply = false; out.append(e)
            }
        }
        return out
    }

    private func prefix(_ k: SCPILogEntry.Kind) -> String {
        switch k { case .write: "→"; case .query: "?"; case .reply: "←"; case .error: "!"; case .info: "·" }
    }
    private func color(_ k: SCPILogEntry.Kind) -> Color {
        switch k { case .write: .blue; case .query: .purple; case .reply: .green; case .error: .red; case .info: .secondary }
    }
}
