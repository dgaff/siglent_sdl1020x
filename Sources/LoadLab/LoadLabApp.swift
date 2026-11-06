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
                Button("Scan Network") { Task { await app.scan() } }
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Safety: never leave the load sinking because the app quit.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session = app?.session, session.state.inputOn else { return .terminateNow }
        Task {
            await session.emergencyOff()
            await session.disconnect()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
