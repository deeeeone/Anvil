import SwiftUI

@main
struct AnvilMain {
    static func main() {
        if CommandLine.arguments.contains("--headless") { Headless.main() }
        if let path = Headless.value("--parse") { Headless.parseFile(path) }
        AnvilApp.main()
    }
}

struct AnvilApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup(AppInfo.name) {
            ContentView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { app.newSession() }.keyboardShortcut("n")
                Button("Open Folder…") { app.chooseProject() }.keyboardShortcut("o")
            }
            CommandMenu("Agent") {
                Button("Stop") { app.current?.stop() }.keyboardShortcut(".", modifiers: .command)
                Button("Cycle Permission Mode") { if let c = app.current { c.mode = c.mode.next } }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Undo Last Task's Changes") { app.current?.undoLast() }.keyboardShortcut("z", modifiers: [.command, .option])
                Divider()
                Button("Toggle Inspector") { app.showInspector.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
        Settings {
            SettingsView().environment(app)
        }
    }
}
