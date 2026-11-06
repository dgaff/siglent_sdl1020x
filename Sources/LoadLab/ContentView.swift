import SwiftUI
import LoadLabCore
import SDLKit

struct ContentView: View {
    @Bindable var app: AppModel
    @AppStorage("chart.visible") private var chartVisible = true
    @State private var showSettings = false
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if app.page == .library {
                LibraryView(library: app.library)
            } else if app.page == .profiles {
                if let session = app.session, session.link.isUsable {
                    VStack(spacing: 0) {
                        ReadoutBar(session: session)
                        Divider()
                        ProfilesPane(session: session)
                    }
                } else {
                    ProfilesPane(session: nil)
                }
            } else if let session = app.session, session.link != .disconnected {
                detail(session)
            } else {
                welcome
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if let s = app.session, s.link != .disconnected {
                    Button { showSettings = true } label: { Label("Instrument Settings", systemImage: "gearshape") }
                        .help("Sense, Von, protection, averaging, trigger…")
                        .disabled(!s.link.isUsable)
                    Toggle(isOn: $chartVisible) { Label("Chart", systemImage: "chart.xyaxis.line") }
                        .help("Show or hide the live chart")
                    Button { Task { await app.disconnect() } } label: { Label("Disconnect", systemImage: "eject") }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            if let s = app.session { SettingsSheet(session: s) }
        }
        .task {
            // `--connect host[:port]` (used for testing and scripted launches).
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--connect"), i + 1 < args.count {
                let parts = args[i + 1].split(separator: ":")
                let host = String(parts[0]), port = parts.count > 1 ? UInt16(parts[1]) ?? 5025 : 5025
                app.upsert(host: host, port: port)
                if let d = app.devices.first(where: { $0.host == host && $0.port == port }) { await app.connect(d) }
                // Test hook: auto-start a demo run, only ever against the simulator.
                if ProcessInfo.processInfo.environment["LOADLAB_DEMO_RUN"] == "1",
                   let s = app.session, s.identity?.serial.hasPrefix("SIM") == true {
                    var c = BatteryConfig(); c.mode = .cc; c.level = 1.5; c.currentRange = .high; c.voltageRange = .low
                    c.stopVoltageEnabled = true; c.stopVoltage = 3.0
                    var cell = CellInfo(); cell.name = "Demo 18650"; cell.nominalCapacity_mAh = 60
                    var o = RecordingOptions(); o.sampleRateHz = 5
                    try? await s.startBatteryRun(config: c, cell: cell, options: o)
                    app.selectedFunction = .battery
                }
                // Test hook: a short HPPC-style profile on a simulated cell (simulator only).
                if ProcessInfo.processInfo.environment["LOADLAB_DEMO_PROFILE"] == "1",
                   let s = app.session, s.identity?.serial.hasPrefix("SIM") == true {
                    _ = await s.raw("SIM:BATTERY 8,4.2,3.0")
                    _ = await s.raw("SIM:SOURCE:RES 0.06")
                    var p = Profile(name: "Demo IR vs SoC", steps: [
                        .loop([.rest(3), .dcr(i1: 0.1, t1: 2, i2: 0.9, t2: 1), .hold(.cc, 0.8, untilCapacity: 1.2)], count: 8)
                    ])
                    p.limits.cutoffVoltage = 3.2; p.limits.maxCurrent = 0.9; p.sampleRateHz = 5
                    var cell = CellInfo(); cell.name = "Demo cell"; cell.nominalCapacity_mAh = 8
                    try? await s.startProfileRun(p, cell: cell)
                    app.page = .profiles
                }
            } else if app.devices.isEmpty && !args.contains("--library") && !args.contains("--profiles") {
                await app.scan()
            }
            // After connecting (which picks the instrument's own screen).
            if args.contains("--library") { app.page = .library }
            if args.contains("--profiles") { app.page = .profiles }
        }
    }

    @ViewBuilder
    private func detail(_ session: DeviceSession) -> some View {
        if case .failed(let why) = session.link {
            ContentUnavailableView {
                Label("Couldn't connect", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(why)
            } actions: {
                Button("Try Again") { Task { await session.connect() } }
            }
        } else if session.link == .connecting {
            ProgressView("Connecting to \(session.host)…")
        } else {
            VStack(spacing: 0) {
                ReadoutBar(session: session)
                Divider()
                VSplitView {
                    functionPane(session)
                        .frame(minHeight: 220)
                    // The Battery screen is a long form plus its own run charts.
                    if chartVisible && app.selectedFunction != .battery {
                        LiveChartView(session: session)
                            .frame(minHeight: 180, idealHeight: 300)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func functionPane(_ session: DeviceSession) -> some View {
        switch app.selectedFunction {
        case .basic: BasicPane(session: session)
        case .battery: BatteryPane(session: session)
        case .list: ComingSoon(function: .list, phase: 6, session: session)
        case .program: ComingSoon(function: .program, phase: 6, session: session)
        case .ocpt, .oppt: ComingSoon(function: .ocpt, phase: 6, session: session)
        case .ext: ComingSoon(function: .ext, phase: 6, session: session)
        }
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("LoadLab", systemImage: "bolt.batteryblock")
        } description: {
            Text(app.scanning ? "Scanning the network for SDL1000X loads…"
                              : "Click Connect next to an instrument in the sidebar, or add one by IP.")
        } actions: {
            Button("Scan Network") { Task { await app.scan() } }.disabled(app.scanning)
        }
    }
}

private struct ComingSoon: View {
    let function: ActiveFunction
    let phase: Int
    let session: DeviceSession
    var body: some View {
        ContentUnavailableView {
            Label(function == .ocpt ? "OCPT / OPPT" : function.label, systemImage: function.symbol)
        } description: {
            Text("This screen arrives in Phase \(phase). The instrument is currently running: \(session.state.function.label).")
        }
    }
}
