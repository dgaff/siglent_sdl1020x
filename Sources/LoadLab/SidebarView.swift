import SwiftUI
import LoadLabCore

enum SidebarDestination: Hashable {
    case function(ActiveFunction)
    case profiles
    case library
}

struct SidebarView: View {
    @Bindable var app: AppModel
    @State private var showAdd = false
    @State private var newHost = ""
    @State private var selection: SidebarDestination?

    private var modelDestination: SidebarDestination {
        if app.page == .library { return .library }
        if app.page == .profiles { return .profiles }
        // OPPT shares the OCPT row.
        return .function(app.selectedFunction == .oppt ? .ocpt : app.selectedFunction)
    }

    var body: some View {
        // Row tags are plain `SidebarDestination` (not Optional): on this macOS, Optional-wrapped
        // tags never match and every click is silently ignored. Checked with an accessibility
        // selection test (select a row, read back which row is selected).
        List(selection: $selection) {
            Section {
                ForEach(app.devices) { d in
                    // No tap gestures in this List: on macOS they swallow the List's own clicks
                    // and break row selection. Connecting uses an explicit button instead.
                    DeviceRow(device: d, session: app.session?.host == d.host && app.session?.port == d.port ? app.session : nil) {
                        Task { await app.connect(d) }
                    }
                    .contextMenu {
                        Button("Connect") { Task { await app.connect(d) } }
                        Button("Remove", role: .destructive) { app.remove(d) }
                    }
                }
                if app.devices.isEmpty && !app.scanning {
                    Text("No instruments yet. Scan the network or add one by IP.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Instruments")
                    Spacer()
                    if app.scanning { ProgressView().controlSize(.mini) }
                    Button { Task { await app.scan() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Scan the local network (TCP 5025)")
                        .disabled(app.scanning)
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Add an instrument by IP address")
                }
            }

            Section("Functions") {
                ForEach([ActiveFunction.basic, .battery, .list, .program, .ocpt, .ext], id: \.self) { f in
                    Label(f == .ocpt ? "OCPT / OPPT" : f.label, systemImage: f.symbol)
                        .badge(badge(f))
                        .tag(SidebarDestination.function(f))
                }
            }

            Section("Battery Lab") {
                Label("Profiles", systemImage: "list.bullet.rectangle")
                    .badge(app.session?.recorder?.isActive == true && app.session?.recorder?.info.kind == "profile" ? Text("● run") : nil)
                    .tag(SidebarDestination.profiles)
                Label("Runs", systemImage: "books.vertical")
                    .badge(app.library.entries.isEmpty ? nil : Text("\(app.library.entries.count)"))
                    .tag(SidebarDestination.library)
            }
        }
        .listStyle(.sidebar)
        .onAppear { selection = modelDestination }
        // Model → sidebar (e.g. connecting jumps to the instrument's active function).
        .onChange(of: modelDestination) { _, new in if selection != new { selection = new } }
        // Sidebar → model.
        .onChange(of: selection) { _, new in
            switch new {
            case .library?: app.page = .library
            case .profiles?: app.page = .profiles
            case .function(let f)?: app.page = .function; app.selectedFunction = f
            case nil: break
            }
        }
        .task { await app.library.reload() }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    private func badge(_ f: ActiveFunction) -> Text? {
        if f == .battery, app.session?.recorder?.isActive == true, app.session?.recorder?.info.kind != "profile" { return Text("● rec") }
        if let r = app.session?.sequence, r.phase == .running, r.function == f || (f == .ocpt && r.function == .oppt) { return Text("● run") }
        return isActive(f) ? Text("active") : nil
    }

    private func isActive(_ f: ActiveFunction) -> Bool {
        guard let s = app.session, s.link.isUsable else { return false }
        return s.state.function == f || (f == .ocpt && s.state.function == .oppt)
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add instrument").font(.headline)
            TextField("IP address or host name (optionally :port)", text: $newHost)
                .textFieldStyle(.roundedBorder).frame(width: 320)
                .onSubmit(add)
            HStack {
                Spacer()
                Button("Cancel") { showAdd = false }.keyboardShortcut(.cancelAction)
                Button("Add & Connect", action: add).keyboardShortcut(.defaultAction)
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func add() {
        let raw = newHost.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        let parts = raw.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 5025 : 5025
        app.upsert(host: host, port: port)
        showAdd = false
        newHost = ""
        if let d = app.devices.first(where: { $0.host == host && $0.port == port }) {
            Task { await app.connect(d) }
        }
    }
}

private struct DeviceRow: View {
    let device: KnownDevice
    let session: DeviceSession?
    let connect: () -> Void

    private var connected: Bool {
        guard let s = session else { return false }
        switch s.link { case .connected, .connecting, .reconnecting: return true; default: return false }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.title).lineLimit(1)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if !connected {
                Button("Connect", action: connect)
                    .controlSize(.small)
                    .help("Connect to \(device.host)")
            }
        }
    }

    private var status: String {
        if let s = session { return s.link == .connected ? "Connected · \(device.host)" : s.link.label }
        if device.busy { return "Busy: another program is connected" }
        return device.subtitle
    }

    private var color: Color {
        guard let s = session else { return device.busy ? .orange : .gray }
        switch s.link {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }
}

extension ActiveFunction {
    var symbol: String {
        switch self {
        case .basic: "slider.horizontal.3"
        case .battery: "battery.75percent"
        case .list: "list.number"
        case .program: "checklist"
        case .ocpt, .oppt: "chart.line.uptrend.xyaxis"
        case .ext: "cable.connector"
        }
    }
}
