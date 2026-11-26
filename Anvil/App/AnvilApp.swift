import SwiftUI

@main
struct AnvilMain {
    static func main() {
        if CommandLine.arguments.contains("--headless") { Headless.main() }
        if let path = Headless.value("--parse") { Headless.parseFile(path) }
        AnvilApp.main()
    }
}

/// Quitting never blocks the main thread. When lid-closed mode needs undoing (which shows macOS's password
/// prompt), Anvil asks to quit a moment later, brings itself forward so the prompt is visible, undoes it, then quits.
final class AnvilAppDelegate: NSObject, NSApplicationDelegate {
    private var quitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, UserDefaults.standard.bool(forKey: "lidModeSetByAnvil") else { return .terminateNow }
        quitting = true
        Task { @MainActor in
            if await KeepAwake.lidClosedModeOn() {
                NSApp.activate(ignoringOtherApps: true)
                let problem = await withTaskGroup(of: String?.self) { g -> String? in
                    g.addTask { await KeepAwake.setLidClosedMode(false) }
                    g.addTask { try? await Task.sleep(for: .seconds(90)); return "timed out" }
                    let first = await g.next() ?? nil
                    g.cancelAll()
                    return first
                }
                if problem != nil {
                    Notifier.shared.post(id: "lid-mode", title: "Lid-closed mode is still on",
                                         body: "Your Mac won't sleep with the lid closed. Turn it off in Anvil's Settings or run: sudo pmset -a disablesleep 0",
                                         category: "done", session: "")
                }
            } else {
                UserDefaults.standard.set(false, forKey: "lidModeSetByAnvil")   // already off: nothing to undo
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct AnvilApp: App {
    @NSApplicationDelegateAdaptor(AnvilAppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            ContentView()
                .environment(app)
                .frame(minWidth: 640, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { app.newSession() }.keyboardShortcut("n")
                Button("Open Folder…") { app.chooseProject() }.keyboardShortcut("o")
            }
            CommandMenu("Go") {
                Button("Command Palette") { PaletteState.shared.toggle(app) }.keyboardShortcut("k")
                Divider()
                ForEach(1...9, id: \.self) { n in
                    Button("Session \(n)") { if app.sessions.indices.contains(n - 1) { app.select(app.sessions[n - 1].id) } }
                        .keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
                }
                Divider()
                Button("Next Recent Session") { PaletteState.shared.switchRecent(app, backward: false) }.keyboardShortcut(.tab, modifiers: .control)
                Button("Previous Recent Session") { PaletteState.shared.switchRecent(app, backward: true) }.keyboardShortcut(.tab, modifiers: [.control, .shift])
            }
            CommandMenu("Agent") {
                Button("Stop") { app.current?.stop() }.keyboardShortcut(".", modifiers: .command)
                Button("Cycle Permission Mode") { if let c = app.current { c.mode = c.mode.next } }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Undo Last Task's Changes") { app.current?.undoLast() }.keyboardShortcut("z", modifiers: [.command, .option])
                Divider()
                Button("Toggle Sidebar") { app.showSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("Toggle Inspector") { app.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Toggle Split View") { app.toggleSplit() }.keyboardShortcut("\\", modifiers: .command)
                Button("Focus Left Pane") { app.focusPane(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(!app.panes.isSplit)
                Button("Focus Right Pane") { app.focusPane(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(!app.panes.isSplit)
            }
        }
        Settings {
            SettingsView().environment(app).preferredColorScheme(.dark)
        }
    }
}
