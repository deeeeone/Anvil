import AppKit
import SwiftTerm
import Observation

/// Terminal tabs like Claude Code's: one tab streaming the agent's commands, a tab per background process,
/// and real interactive shells (SwiftTerm: full emulation, colours, scrollback, autoscroll).
@Observable
final class TerminalStore {
    struct Tab: Identifiable, Equatable {
        enum Kind: Equatable { case agent, process(String), shell }
        let id = UUID()
        var kind: Kind
        var title: String
        var running = true
    }

    private(set) var tabs: [Tab] = [Tab(kind: .agent, title: "Agent")]
    var selected: UUID?
    @ObservationIgnored private var views: [UUID: TerminalView] = [:]
    @ObservationIgnored private var fed: [String: Int] = [:]   // process name → characters already shown
    @ObservationIgnored private var delegates: [UUID: ShellDelegate] = [:]

    var agentTab: Tab { tabs[0] }

    static func style(_ v: TerminalView) {
        v.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        v.nativeBackgroundColor = NSColor(srgbRed: 0.02, green: 0.02, blue: 0.024, alpha: 1)
        v.nativeForegroundColor = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.87, alpha: 1)
        v.caretColor = NSColor(srgbRed: 0xD9/255, green: 0x77/255, blue: 0x57/255, alpha: 1)
        v.optionAsMetaKey = true
    }

    func view(for tab: Tab, cwd: URL) -> TerminalView {
        if let v = views[tab.id] { return v }
        let v: TerminalView
        switch tab.kind {
        case .shell:
            let shell = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let d = ShellDelegate { [weak self] in self?.markExited(tab.id) } title: { [weak self] t in self?.retitle(tab.id, t) }
            delegates[tab.id] = d
            shell.processDelegate = d
            var env = ProcessRunner.environment().map { "\($0.key)=\($0.value)" }
            env.removeAll { $0.hasPrefix("TERM=") || $0.hasPrefix("NO_COLOR=") || $0.hasPrefix("CI=") || $0.hasPrefix("PAGER=") || $0.hasPrefix("GIT_PAGER=") }
            env += ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8"]
            let sh = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            shell.startProcess(executable: sh, args: ["-l"], environment: env, execName: "-" + (sh as NSString).lastPathComponent, currentDirectory: cwd.path)
            v = shell
        default:
            v = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        }
        Self.style(v)
        views[tab.id] = v
        return v
    }

    func newShell() {
        let n = tabs.filter { $0.kind == .shell }.count + 1
        let t = Tab(kind: .shell, title: "zsh \(n)")
        tabs.append(t)
        selected = t.id
    }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), tabs[i].kind != .agent else { return }
        (views[id] as? LocalProcessTerminalView)?.terminate()
        views[id] = nil
        delegates[id] = nil
        tabs.remove(at: i)
        if selected == id { selected = tabs.last?.id }
    }

    private func markExited(_ id: UUID) { if let i = tabs.firstIndex(where: { $0.id == id }) { tabs[i].running = false } }
    private func retitle(_ id: UUID, _ t: String) { if let i = tabs.firstIndex(where: { $0.id == id }), !t.isEmpty { tabs[i].title = Fmt.line(t, 24) } }

    /// Agent command output: a coloured header per command, then its output as it streams.
    func agentCommand(_ title: String) {
        feed(agentTab.id, "\r\n\u{1b}[38;2;217;119;87m❯ \(title)\u{1b}[0m\r\n")
    }
    func agentOutput(_ chunk: String) { feed(agentTab.id, chunk) }

    /// Background processes get a tab each; new output is appended as it arrives.
    func syncProcesses(_ entries: [ProcessManager.Entry]) {
        for e in entries {
            if !tabs.contains(where: { $0.kind == .process(e.name) }) {
                tabs.append(Tab(kind: .process(e.name), title: e.name))
            }
            let all = e.output.value
            let shown = fed[e.name] ?? 0
            if all.count > shown, let id = tabs.first(where: { $0.kind == .process(e.name) })?.id {
                feed(id, String(all.suffix(all.count - shown)))
                fed[e.name] = all.count
            }
            if let i = tabs.firstIndex(where: { $0.kind == .process(e.name) }) { tabs[i].running = e.running }
        }
    }

    private func feed(_ id: UUID, _ text: String) {
        guard let v = views[id] ?? tabs.first(where: { $0.id == id }).map({ view(for: $0, cwd: Paths.home) }) else { return }
        v.feed(text: text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))
    }
}

final class ShellDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let exited: () -> Void
    let title: (String) -> Void
    init(exited: @escaping () -> Void, title: @escaping (String) -> Void) { self.exited = exited; self.title = title }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { self.title(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { exited() }
}
