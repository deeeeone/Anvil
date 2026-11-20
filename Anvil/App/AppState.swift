import Foundation
import Observation
import AppKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case changes = "Changes", todo = "Todo", terminal = "Terminal", git = "Git"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .changes: return "plusminus"; case .todo: return "checklist"; case .terminal: return "terminal"; case .git: return "arrow.triangle.branch" }
    }
}

/// The open project, its sessions and UI selection.
@Observable
final class AppState {
    private(set) var project: URL?
    private(set) var sessions: [SessionSummary] = []
    private(set) var current: SessionController?
    let processes = ProcessManager()
    var inspectorTab: InspectorTab? = .changes
    var showInspector = true
    var showModelPicker = false
    var selectedDiff: FileDiff?
    var previewFile: URL?
    private(set) var git = Git.Status(isRepo: false)
    @ObservationIgnored private var controllers: [UUID: SessionController] = [:]

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.processes.stopAll()
                MCPManager.shared.stopAll()
                self?.controllers.values.forEach { $0.saveNow() }
            }
        }
        if !AppInfo.isTesting, let last = RecentProjects.list().first { open(last) }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        let root = url.standardizedFileURL
        guard root != project else { return }
        current?.saveNow()
        processes.stopAll()
        controllers = [:]
        project = root
        RecentProjects.add(root)
        MCPManager.shared.start(project: root)
        refreshSessions()
        if let first = sessions.first { select(first.id) } else { newSession() }
        refreshGit()
    }

    func refreshSessions() {
        guard let project else { sessions = []; return }
        var list = SessionStore.list(root: project)
        // The current session may not be saved yet.
        if let c = current, !list.contains(where: { $0.id == c.session.id }) {
            list.insert(SessionSummary(id: c.session.id, title: c.session.title, updated: c.session.updated, cost: c.session.usage.cost), at: 0)
        }
        if let c = current, let i = list.firstIndex(where: { $0.id == c.session.id }) { list[i].title = c.session.title }
        sessions = list
    }

    func newSession() {
        guard let project else { return }
        current?.saveNow()
        let s = Session(projectPath: project.path)
        let c = SessionController(session: s, root: project, processes: processes)
        c.app = self
        controllers[s.id] = c
        current = c
        selectedDiff = nil
        refreshSessions()
    }

    func select(_ id: UUID) {
        guard let project, current?.session.id != id else { return }
        current?.saveNow()
        if let c = controllers[id] { current = c }
        else if let s = SessionStore.load(id, root: project) {
            let c = SessionController(session: s, root: project, processes: processes)
            c.app = self
            controllers[id] = c
            current = c
        }
        selectedDiff = current?.changedDiffs.last
    }

    func delete(_ id: UUID) {
        guard let project else { return }
        controllers[id]?.stop()
        controllers[id] = nil
        SessionStore.delete(id, root: project)
        if current?.session.id == id { current = nil }
        refreshSessions()
        if current == nil { if let f = sessions.first { select(f.id) } else { newSession() } }
    }

    func refreshGit() {
        guard let project else { return }
        Task { git = await Git.status(project) }
    }

    func resetAgents() { controllers.values.forEach { $0.resetAgent() } }
}
