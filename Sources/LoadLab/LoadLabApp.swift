import SwiftUI
import AppKit
import LoadLabCore

@main
struct LoadLabApp: App {
    @State private var app = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("LoadLab", id: "main") {
            ContentView(app: app)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { delegate.app = app }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandMenu("Load") {
                Button("Toggle Input") {
                    Task { if let s = app.session { await s.setInput(!s.state.inputOn) } }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(app.session?.link.isUsable != true)
                Button("Emergency Input Off") {
                    Task { await app.session?.emergencyOff() }
                }
                .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("Instrument Settings…") { app.showingInstrumentSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(app.session?.link.isUsable != true)
                Button("Scan Network") { Task { await app.scan() } }
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array([ActiveFunction.basic, .battery, .list, .program, .ocpt, .ext].enumerated()), id: \.offset) { i, f in
                    Button(f == .ocpt ? "OCPT / OPPT" : f.label) { app.go(f) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Button("Profiles") { app.page = .profiles }.keyboardShortcut("7", modifiers: .command)
                Button("Runs") { app.page = .library }.keyboardShortcut("8", modifiers: .command)
                Divider()
            }
        }

        Window("SCPI Console", id: "console") {
            ConsoleView(app: app).frame(minWidth: 560, minHeight: 400)
        }
        .keyboardShortcut("k", modifiers: [.command, .option])
    }
}

/// Makes `swift run` behave like a bundled app, and switches the input off on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var app: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Test hook for appearance checks: LOADLAB_APPEARANCE=dark|light.
        switch ProcessInfo.processInfo.environment["LOADLAB_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Safety: never leave the load sinking because the app quit — except a Battery test the
    /// user chooses to leave running (the instrument enforces its own stop conditions and
    /// LoadLab resumes recording when it reconnects).
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = app?.session else { return .terminateNow }
        let recorder = session.recorder?.isActive == true ? session.recorder : nil
        let sequenceRunning = session.sequence?.phase == .running
        guard session.state.inputOn || recorder != nil || sequenceRunning else { return .terminateNow }

        var keepRunning = false
        if recorder != nil || sequenceRunning {
            let alert = NSAlert()
            alert.alertStyle = .warning
            if let r = recorder, r.info.kind != "profile" {
                alert.messageText = "A battery test is recording."
                alert.informativeText = "You can leave it running: the instrument stops it at its own stop conditions, and LoadLab picks the recording up again when it reconnects. Or stop the test (input off) and quit."
                alert.addButton(withTitle: "Stop Test & Quit")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit, Leave Test Running")
            } else {
                let what = recorder != nil ? "A profile" : "A \(session.sequence?.function.label ?? "") run"
                alert.messageText = "\(what) is running."
                alert.informativeText = "It can't continue without LoadLab. Quitting switches the input off."
                alert.addButton(withTitle: "Stop & Quit")
                alert.addButton(withTitle: "Cancel")
            }
            switch alert.runModal() {
            case .alertFirstButtonReturn: break
            case .alertThirdButtonReturn: keepRunning = true
            default: return .terminateCancel
            }
        }
        Task {
            if !keepRunning { await session.emergencyOff() }
            await session.disconnect()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
