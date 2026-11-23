import Foundation
import Observation
import AppKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case changes = "Changes", preview = "Preview", device = "Device", files = "Files", todo = "Plan", terminal = "Terminal", git = "Git"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .changes: return "plusminus"; case .preview: return "safari"; case .device: return "iphone"; case .files: return "folder"; case .todo: return "checklist"
        case .terminal: return "terminal"; case .git: return "arrow.triangle.branch"
        }
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
    var showInspector = false
    var showSidebar = true
    /// The window is wide enough to show the inspector beside the conversation.
    var isWide = true
    /// The sidebar floats over the conversation (narrow window): close it after picking something.
    var sidebarFloating = false
    /// The owner closed the inspector this session: don't pop it open again on every edit.
    var inspectorDismissed = false
    var showModelPicker = false
    var showWorktreeCleanup = false
    var selectedDiff: FileDiff?
    var previewFile: URL?
    private(set) var git = Git.Status(isRepo: false)
    /// Bumped when files under the working folder change (the Files tab and git status follow it).
    private(set) var fileTick = 0
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var gitRefreshPending = false
    @ObservationIgnored private var controllers: [UUID: SessionController] = [:]
    /// Background tasks for this project (see TaskQueue.swift).
    var queue: [QueuedTask] = []
    /// Sessions started by other sessions' agents (see SubSessions.swift).
    var subSessions: [SubSession] = []
    /// Instructions waiting for their time (see Schedule.swift).
    var schedules: [ScheduledTask] = []
    @ObservationIgnored var scheduleTimer: Task<Void, Never>?
    @ObservationIgnored var presenceBusy = false
    @ObservationIgnored var presenceTaskStart: Date? { didSet { persistSubSessions() } }
    /// True while a project's saved links are being loaded (so loading doesn't write them back).
    @ObservationIgnored var restoringSubSessions = false
    /// Polls GitHub for labeled issues to queue (see TaskQueue.swift).
    @ObservationIgnored var issueWatch: Task<Void, Never>?
    /// The embedded browser (live preview, and the agent's browser tools).
    let browser = BrowserController()
    /// The Device tab's live simulator view.
    let simulator = SimulatorController()
    /// Terminal tabs (agent output, background processes, shells).
    let terminals = TerminalStore()
    /// The Mac is being kept awake for running work.
    private(set) var keepingAwake = false

    /// A session started or stopped working: hold the Mac awake while anything runs.
    func workingChanged() {
        let busy = controllers.values.contains { $0.running }
        KeepAwake.shared.update(working: busy)
        keepingAwake = KeepAwake.shared.held
        if busy != presenceBusy { presenceBusy = busy; presenceTaskStart = busy ? Date() : nil }
        refreshPresence()
    }

    /// Updates (or removes) the Discord Rich Presence from the current state and settings.
    func refreshPresence() {
        let s = AppSettings.shared
        guard s.discordPresence, !AppInfo.isTesting else { DiscordPresence.shared.update(nil); return }
        let model = current?.model ?? s.model
        let project = s.discordShowProject ? project?.lastPathComponent : nil
        DiscordPresence.shared.update(.init(working: presenceBusy, model: model, project: project, taskStart: presenceTaskStart))
    }

    func controller(for id: UUID) -> SessionController? { controllers[id] }
    func registerController(_ c: SessionController) { controllers[c.session.id] = c }

    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        Notifier.shared.setup()
        Notifier.shared.onOpen = { [weak self] id in if let u = UUID(uuidString: id) { self?.select(u) } }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.processes.stopAll()
                KeepAwake.shared.update(working: false)
                DiscordPresence.shared.shutdown()
                // Lid-closed mode is undone before this, in AnvilAppDelegate.applicationShouldTerminate (never blocking here).
                MCPManager.shared.stopAll()
                LSP.stopAll()
                ProviderServers.shared.stopAll()
                self?.controllers.values.forEach { $0.saveNow() }
            }
        }
        if !AppInfo.isTesting, let last = RecentProjects.list().first { open(last) }
        // Debug: ANVIL_WINDOW=900x700 sizes the window at launch (for checking the responsive layout).
        if let spec = ProcessInfo.processInfo.environment["ANVIL_WINDOW"] {
            let n = spec.split(separator: "x").compactMap { Double($0) }
            if n.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                    w.setFrame(NSRect(x: w.frame.minX, y: w.frame.maxY - n[1], width: n[0], height: n[1]), display: true, animate: false)
                }
            }
        }
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
        restoringSubSessions = true
        subSessions = []
        project = root
        subSessions = SubSession.load(root)
        restoringSubSessions = false
        RecentProjects.add(root)
        queue = QueuedTask.load(root)
        MCPManager.shared.start(project: root)
        refreshSessions()
        if let first = sessions.first { select(first.id) } else { newSession() }
        refreshGit()
        refreshBrief(root)
        processQueue()
        refreshPresence()
        watchGitHubIssues()
        loadSchedules()
        startScheduleTimer()
    }

    /// Keep the project brief current in the background (one cheap call only when the project's shape changed).
    func refreshBrief(_ root: URL) {
        let s = AppSettings.shared
        guard s.projectBrief else { return }
        let model = s.quickModel.isEmpty ? s.model : s.quickModel
        guard let brain = try? Brain.fromSettings(model: model) else { return }
        brain.onUsage = { [weak self] u, _, cost in self?.current?.session.usage.add(u, cost: cost) }
        Task { await Agent.refreshBrief(root: root, brain: brain) }
    }

    func refreshSessions() {
        guard let project else { sessions = []; return }
        var list = SessionStore.list(root: project)
        // The current session may not be saved yet.
        if let c = current, !list.contains(where: { $0.id == c.session.id }) {
            list.insert(SessionSummary(id: c.session.id, title: c.session.title, updated: c.session.updated, cost: c.session.usage.cost, branch: c.session.branch), at: 0)
        }
        if let c = current, !list.contains(where: { $0.id == c.session.id }) {}
        if let c = current, let i = list.firstIndex(where: { $0.id == c.session.id }) { list[i].title = c.session.title; list[i].branch = c.session.branch }
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

    /// A session on its own branch in its own git worktree (folder next to the project), merged back when done.
    func newWorktreeSession() {
        guard let project else { return }
        Task {
            switch await Git.addWorktree(project, name: "session") {
            case .failure(let e):
                newSession()
                current?.append(ChatItem(kind: .error, text: (e as? ToolFailure)?.message ?? e.localizedDescription))
            case .success(let (dir, branch, base)):
                current?.saveNow()
                var s = Session(projectPath: project.path)
                s.workdir = dir.path
                s.branch = branch
                s.baseBranch = base
                s.title = "New session on \(branch)"
                let c = SessionController(session: s, root: dir, processes: processes)
                c.app = self
                controllers[s.id] = c
                current = c
                c.append(ChatItem(kind: .system, text: "Working in a git worktree on branch \(branch) (from \(base)), folder \(Paths.display(dir, root: nil)). Your checkout of \(project.lastPathComponent) stays untouched. Merge it from the Git tab when you're happy."))
                selectedDiff = nil
                refreshSessions()
                refreshGit()
            }
        }
    }

    func select(_ id: UUID) {
        guard let project, current?.session.id != id else { return }
        current?.saveNow()
        if let c = controllers[id] { current = c }
        else if let s = SessionStore.load(id, root: project) {
            let c = SessionController(session: s, root: s.root, processes: processes)
            c.app = self
            controllers[id] = c
            if subSessions.contains(where: { $0.id == id }) { wireSubSession(c) }
            current = c
        }
        selectedDiff = current?.changedDiffs.last
        refreshGit()
    }

    /// A new session that continues `id`'s conversation: all of it, or (with `itemID`, one of your messages) up to just
    /// before that message, which goes into the new composer to edit. Files and the original session are untouched.
    func fork(_ id: UUID, at itemID: UUID?) {
        guard let project else { return }
        controllers[id]?.saveNow()
        guard let source = controllers[id]?.session ?? SessionStore.load(id, root: project) else { return }
        var s = Session(projectPath: source.projectPath)
        s.workdir = source.workdir
        s.branch = source.branch
        s.baseBranch = source.baseBranch
        s.model = source.model
        s.mode = source.mode
        s.allowedCommands = source.allowedCommands
        s.costLimit = source.costLimit
        s.stepLimit = source.stepLimit
        s.briefing = source.briefing
        s.briefedTools = source.briefedTools
        s.compactedAt = source.compactedAt
        s.title = "Fork: " + source.title.replacingOccurrences(of: "Fork: ", with: "")
        var draft: String?
        if let itemID, let idx = source.items.firstIndex(where: { $0.id == itemID }), source.items[idx].kind == .user {
            let item = source.items[idx]
            s.items = Array(source.items.prefix(idx))
            let conversationOK = item.historyIndex.map { $0 <= source.messages.count } == true && !(source.compactedAt.map { $0 > item.date } ?? false)
            if conversationOK, let h = item.historyIndex {
                s.messages = Array(source.messages.prefix(h))
            } else {
                s.messages = []
                s.briefing = ""
            }
            draft = item.text
        } else {
            s.items = source.items
            s.messages = source.messages
            s.todos = source.todos
            s.plan = source.plan
        }
        // Checkpoints stay with the original: undoing in the fork must not touch the original's changes.
        s.items.append(ChatItem(kind: .system, text: "Forked from \u{201C}\(Fmt.line(source.title, 60))\u{201D}. Files are shared with it: nothing was restored."))
        current?.saveNow()
        let root = URL(fileURLWithPath: s.workdir ?? s.projectPath)
        let c = SessionController(session: s, root: root, processes: processes)
        c.app = self
        c.draft = draft
        controllers[s.id] = c
        current = c
        c.saveNow()
        selectedDiff = nil
        refreshSessions()
    }

    func delete(_ id: UUID) {
        guard let project else { return }
        controllers[id]?.stop()
        controllers[id] = nil
        subSessions.removeAll { $0.id == id }
        SessionStore.delete(id, root: project)
        if current?.session.id == id { current = nil }
        refreshSessions()
        if current == nil { if let f = sessions.first { select(f.id) } else { newSession() } }
    }

    func refreshGit() {
        guard let root = current?.root ?? project else { return }
        watch(root)
        Task { git = await Git.status(root) }
    }

    /// Follow the folder the current session works in (the project, or its worktree).
    private func watch(_ root: URL) {
        guard watcher?.path != root.path else { return }
        watcher?.stop()
        watcher = FileWatcher(path: root.path) { [weak self] in self?.filesChanged() }
        fileTick += 1
    }

    private func filesChanged() {
        fileTick += 1
        if let root = current?.root ?? project { FileIndex.of(root).invalidate() }
        // Git status at most every 0.8 s, however many files change.
        guard !gitRefreshPending else { return }
        gitRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.gitRefreshPending = false
            if let root = self.current?.root ?? self.project { Task { self.git = await Git.status(root) } }
        }
    }

    /// The agent changed files: show the diff beside the chat when there's room for it.
    func revealChanges() {
        inspectorTab = .changes
        if isWide && !inspectorDismissed { showInspector = true }
    }

    func resetAgents() { controllers.values.forEach { $0.resetAgent() } }
}
