import SwiftUI
import LoadLabCore
import SDLKit

struct ContentView: View {
    @Bindable var app: AppModel
    @AppStorage("chart.visible") private var chartVisible = true
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
                    Button { app.showingInstrumentSettings = true } label: { Label("Instrument Settings", systemImage: "gearshape") }
                        .help("Sense, Von, protection, averaging, trigger…")
                        .disabled(!s.link.isUsable)
                    Toggle(isOn: $chartVisible) { Label("Chart", systemImage: "chart.xyaxis.line") }
                        .help("Show or hide the live chart")
                    Button { Task { await app.disconnect() } } label: { Label("Disconnect", systemImage: "eject") }
                }
            }
        }
        .sheet(isPresented: $app.showingInstrumentSettings) {
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
                // Test hook: run a List / Program / OCPT demo on the simulator.
                if let which = ProcessInfo.processInfo.environment["LOADLAB_DEMO_SEQ"],
                   let s = app.session, s.identity?.serial.hasPrefix("SIM") == true {
                    _ = await s.raw("SIM:SOURCE:ILIM 0.5")
                    switch which {
                    case "list":
                        await s.enterFunction(.list); await s.loadList()
                        var c = s.state.list; c.mode = .cc; c.currentRange = .low; c.count = 3
                        c.steps = [ListStep(level: 0.1, width: 2), ListStep(level: 0.3, width: 2), ListStep(level: 0.45, width: 2)]
                        await s.applyList(c)
                        app.selectedFunction = .list
                        try? await s.startSequence(.list)
                    case "program":
                        await s.enterFunction(.program); await s.loadProgram()
                        var a = ProgramStep(); a.mode = .cc; a.currentRange = .low; a.voltageRange = .high; a.level = 0.2
                        a.timeOn = 1; a.timeOff = 0.5; a.timeDelay = 0.5; a.min = 11.9; a.max = 12.1
                        var b = a; b.level = 0.4; b.min = 11.99; b.max = 12.1
                        var c = s.state.program; c.steps = [a, b, a]
                        await s.applyProgram(c)
                        app.selectedFunction = .program
                        try? await s.startSequence(.program)
                    default:
                        await s.enterFunction(.ocpt); await s.loadProtectionTest(.ocpt)
                        var c = s.state.ocpt; c.currentRange = .low; c.voltageRange = .low
                        c.start = 0.1; c.step = 0.05; c.stepDelay = 0.3; c.end = 0.8; c.min = 0.4; c.max = 0.6; c.voltage = 6
                        await s.applyProtectionTest(.ocpt, c)
                        app.selectedFunction = .ocpt
                        try? await s.startSequence(.ocpt)
                    }
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
                        // List / Program / OCPT / Ext carry their own tables and run controls.
                        .frame(minHeight: app.selectedFunction == .basic ? 220 : 450)
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
        case .list: ListPane(session: session)
        case .program: ProgramPane(session: session)
        case .ocpt, .oppt: ProtectionTestPane(session: session)
        case .ext: ExtPane(session: session)
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
