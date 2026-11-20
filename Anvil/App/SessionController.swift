import Foundation
import Observation
import AppKit

struct PendingPermission: Identifiable {
    let id = UUID()
    let request: PermissionRequest
    let resume: (PermissionAnswer) -> Void
}

struct PendingPlan: Identifiable {
    let id = UUID()
    let itemID: UUID
    let resume: (PlanDecision) -> Void
}

struct PendingQuestion: Identifiable {
    let id = UUID()
    let question: String
    let resume: (String?) -> Void
}

struct TerminalChunk: Identifiable {
    let id = UUID()
    var stepID: UUID
    var title: String
    var text: String
}

/// One open session: owns its agent, runs requests, and turns agent events into chat items.
@Observable
final class SessionController: AgentHost {
    var session: Session
    let root: URL
    let processes: ProcessManager
    weak var app: AppState?

    private(set) var running = false
    private(set) var status = ""
    private(set) var startedAt: Date?
    var pendingPermission: PendingPermission?
    var pendingPlan: PendingPlan?
    var pendingQuestion: PendingQuestion?
    /// Messages typed while the agent works; delivered with its next observation, or run next if it finishes first.
    private(set) var steering: [String] = []
    private(set) var terminal: [TerminalChunk] = []

    @ObservationIgnored private var agent: Agent?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saveWork: DispatchWorkItem?

    init(session: Session, root: URL, processes: ProcessManager) {
        self.session = session
        self.root = root
        self.processes = processes
    }

    var mode: PermissionMode {
        get { session.mode ?? AppSettings.shared.defaultMode }
        set { session.mode = newValue; agent?.mode = newValue; scheduleSave() }
    }

    var model: String {
        get { session.model ?? AppSettings.shared.model }
        set { session.model = newValue; agent?.brain.model = newValue; scheduleSave() }
    }

    var changedDiffs: [FileDiff] { session.items.compactMap(\.tool).flatMap(\.diffs) }

    // MARK: Agent

    private func makeAgent() throws -> Agent {
        if let agent { return agent }
        let brain = try Brain.fromSettings(model: session.model)
        brain.onUsage = { [weak self] u, _, cost in
            self?.session.usage.add(u, cost: cost)
            self?.scheduleSave()
        }
        let ctx = ToolContext(root: root, processes: processes, host: self)
        ctx.shellTimeout = AppSettings.shared.shellTimeout
        ctx.todos = session.todos
        let a = Agent(ctx: ctx, brain: brain, extraTools: MCPManager.shared.toolSpecs)
        a.messages = session.messages
        a.briefing = session.briefing
        a.mode = mode
        a.allowedCommands = Set(session.allowedCommands)
        a.maxSteps = AppSettings.shared.maxSteps
        a.autoCompactTokens = AppSettings.shared.autoCompactTokens
        a.onModeChange = { [weak self] m in self?.session.mode = m; self?.scheduleSave() }
        a.onHistory = { [weak self, weak a] in
            guard let self, let a else { return }
            self.session.messages = a.messages
            self.session.briefing = a.briefing
            self.session.allowedCommands = Array(a.allowedCommands)
            self.scheduleSave()
        }
        a.onCheckpoint = { [weak self] cp in
            guard let self else { return }
            if let i = self.session.checkpoints.firstIndex(where: { $0.id == cp.id }) { self.session.checkpoints[i] = cp } else { self.session.checkpoints.append(cp) }
            self.scheduleSave()
        }
        agent = a
        return a
    }

    /// Drops the cached agent so new settings (key, effort, MCP tools) apply on the next request.
    func resetAgent() { if !running { agent = nil } }

    // MARK: Sending

    func send(_ raw: String, images: [(Data, String)] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        if images.isEmpty, let (name, args) = SlashCommands.split(text) {
            if running && name != "cost" && name != "help" && name != "mode" { append(ChatItem(kind: .system, text: "Wait for the current request to finish (or Stop it) before running /\(name).")); return }
            runCommand(name, args: args, raw: text)
            return
        }
        if running {
            steering.append(text)
            append(ChatItem(kind: .user, text: text, images: images.count))
            append(ChatItem(kind: .system, text: "Queued: it reaches the agent with its next step."))
            return
        }
        start(goal: text, display: text, images: images)
    }

    func start(goal: String, display: String, images: [(Data, String)] = []) {
        append(ChatItem(kind: .user, text: display, images: images.count))
        if session.items.filter({ $0.kind == .user }).count == 1 && session.title == "New session" {
            session.title = Session.title(from: display)
            app?.refreshSessions()
        }
        let agent: Agent
        do { agent = try makeAgent() } catch {
            append(ChatItem(kind: .error, text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            return
        }
        agent.mode = mode
        running = true
        startedAt = Date()
        status = "Thinking"
        let note = images.isEmpty ? "" : "IMAGES THE OWNER PASTED: \(images.count) attached to this message.\n\n"
        task = Task { [weak self] in
            let outcome = await agent.run(goal: goal, images: images, attachmentsNote: note)
            guard let self else { return }
            self.running = false
            self.status = ""
            self.startedAt = nil
            self.task = nil
            self.pendingPermission = nil
            self.pendingPlan = nil
            self.pendingQuestion = nil
            if !outcome.changedFiles.isEmpty { self.app?.refreshGit() }
            self.saveNow()
            if NSApp != nil && !NSApp.isActive { self.notifyDone(outcome) }
            // Anything typed during the run that never reached the agent becomes the next request.
            if !self.steering.isEmpty {
                let next = self.steering.joined(separator: "\n\n")
                self.steering = []
                self.start(goal: next, display: "(continuing with your queued message)")
            }
        }
    }

    func stop() {
        task?.cancel()
        pendingPermission?.resume(.deny("stopped"))
        pendingPlan?.resume(.cancel)
        pendingQuestion?.resume(nil)
        pendingPermission = nil
        pendingPlan = nil
        pendingQuestion = nil
        steering = []
    }

    private func notifyDone(_ o: AgentOutcome) {
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: Slash commands

    func runCommand(_ name: String, args: String, raw: String) {
        let s = AppSettings.shared
        switch name {
        case "init":
            start(goal: ProjectContext.initPrompt + (args.isEmpty ? "" : "\n\nExtra guidance: \(args)"), display: raw)
        case "clear":
            app?.newSession()
        case "compact":
            compact(focus: args.isEmpty ? nil : args)
        case "model":
            if args.isEmpty {
                let info = ModelCatalog.shared.info(model)
                append(ChatItem(kind: .system, text: "Model: \(model)" + (info.map { " (\($0.priceLabel), \($0.contextLabel))" } ?? "") + ". Type /model <id> to switch, or pick one in the toolbar."))
                app?.showModelPicker = true
            } else {
                model = args
                append(ChatItem(kind: .system, text: "This session now uses \(args)."))
            }
        case "cost":
            let u = session.usage
            var t = "This session: \(Fmt.dollars(u.cost)) over \(u.calls) model calls. \(Fmt.tokens(u.prompt)) prompt tokens (\(Fmt.tokens(u.cached)) from cache), \(Fmt.tokens(u.completion)) output."
            t += " Context now: about \(Fmt.tokens(max(u.lastPrompt, Compactor.estimateTokens(session.messages)))) tokens."
            append(ChatItem(kind: .system, text: t))
        case "mode":
            let m: PermissionMode? = ["ask": .ask, "edits": .acceptEdits, "accept": .acceptEdits, "acceptedits": .acceptEdits, "auto": .acceptEdits,
                                      "plan": .plan, "bypass": .bypass, "yolo": .bypass][args.lowercased()]
            if let m { mode = m; append(ChatItem(kind: .system, text: "Permission mode: \(m.label).")) }
            else { append(ChatItem(kind: .system, text: "Mode is \(mode.label). Use /mode ask, edits, plan or bypass.")) }
        case "undo":
            undoLast()
        case "commit":
            Task { await commitAll() }
        case "diff":
            app?.inspectorTab = .git
            app?.showInspector = true
        case "skills":
            let l = SkillLibrary.all(project: root)
            append(ChatItem(kind: .system, text: l.isEmpty ? "No skills found. Add SKILL.md folders to .anvil/skills, ~/.claude/skills or \(SkillLibrary.anvilDir.path)."
                            : l.prefix(40).map { "\($0.name) [\($0.source)]: \(Fmt.line($0.description, 100))" }.joined(separator: "\n")))
        case "mcp":
            append(ChatItem(kind: .system, text: MCPManager.shared.statusLines.joined(separator: "\n")))
        case "effort":
            if AppSettings.efforts.contains(args.lowercased()) {
                s.effort = args.lowercased(); agent?.brain.effort = s.effort
                append(ChatItem(kind: .system, text: "Thinking effort: \(s.effort)."))
            } else { append(ChatItem(kind: .system, text: "Effort is \(s.effort). Use /effort low, medium, high or max.")) }
        case "help":
            append(ChatItem(kind: .system, text: SlashCommands.all(project: root).map { "/\($0.name): \($0.summary)" }.joined(separator: "\n")))
        default:
            if let c = SlashCommands.custom(project: root).first(where: { $0.name == name }) {
                start(goal: c.expand(args), display: raw)
            } else {
                append(ChatItem(kind: .system, text: "Unknown command /\(name). Type /help for the list."))
            }
        }
    }

    func compact(focus: String?) {
        guard !running else { return }
        let agent: Agent
        do { agent = try makeAgent() } catch { append(ChatItem(kind: .error, text: error.localizedDescription)); return }
        guard agent.messages.count >= 2 else { append(ChatItem(kind: .system, text: "Nothing to compact yet.")); return }
        running = true
        status = "Compacting"
        let before = Compactor.estimateTokens(agent.messages)
        task = Task { [weak self] in
            do {
                try await agent.compact(focus: focus)
                let after = Compactor.estimateTokens(agent.messages)
                self?.append(ChatItem(kind: .system, text: "Compacted the conversation: about \(Fmt.tokens(before)) to \(Fmt.tokens(after)) tokens."))
            } catch {
                self?.append(ChatItem(kind: .error, text: "Compacting failed: \(error.localizedDescription)"))
            }
            self?.running = false
            self?.status = ""
            self?.task = nil
            self?.saveNow()
        }
    }

    func undoLast() {
        guard let last = session.checkpoints.last(where: { !$0.restored }) else {
            append(ChatItem(kind: .system, text: "No file changes to undo.")); return
        }
        undo(to: last.id)
    }

    func undo(to id: UUID) {
        do {
            let paths = try Checkpoints.rewind(&session.checkpoints, to: id)
            append(ChatItem(kind: .system, text: paths.isEmpty ? "Nothing to restore." : "Restored \(paths.count) file(s): " + paths.map { Paths.display(URL(fileURLWithPath: $0), root: root) }.joined(separator: ", ")
                            + ". The agent will see the files as they are now."))
            if !paths.isEmpty {
                steeringNoteForUndo(paths)
                app?.refreshGit()
            }
            saveNow()
        } catch {
            append(ChatItem(kind: .error, text: "Undo failed: \(error.localizedDescription)"))
        }
    }

    /// Tells the model about an undo with the next request, so it doesn't assume its edits are still there.
    private func steeringNoteForUndo(_ paths: [String]) {
        guard let agent, !agent.messages.isEmpty else { return }
        let note = "(Note: the owner undid your earlier file changes to: \(paths.map { Paths.display(URL(fileURLWithPath: $0), root: root) }.joined(separator: ", ")). Re-read files before editing them.)"
        if let i = agent.messages.indices.last, agent.messages[i].role == "assistant" {
            agent.messages.append(.user(note))
            agent.messages.append(.assistant("Noted.\n```json\n{\"say\": \"Noted.\", \"actions\": [], \"done\": true}\n```"))
            session.messages = agent.messages
        }
    }

    func commitAll(message: String? = nil) async {
        let st = await Git.status(root)
        guard st.isRepo else { append(ChatItem(kind: .error, text: "This folder isn't a git repository.")); return }
        guard !st.files.isEmpty else { append(ChatItem(kind: .system, text: "Nothing to commit, the working tree is clean.")); return }
        var msg = message ?? ""
        if msg.isEmpty {
            status = "Writing a commit message"
            msg = (try? await generateCommitMessage()) ?? ""
            status = ""
            if msg.isEmpty { append(ChatItem(kind: .error, text: "Couldn't generate a commit message.")); return }
        }
        _ = await Git.stageAll(root)
        let r = await Git.commit(root, message: msg)
        append(ChatItem(kind: r.status == 0 ? .system : .error, text: r.status == 0 ? "Committed:\n\(msg)" : "Commit failed: \(r.combined)"))
        app?.refreshGit()
    }

    func generateCommitMessage() async throws -> String {
        let diff = await Git.fullDiff(root)
        guard !diff.isEmpty else { return "" }
        let brain = try agent?.brain ?? Brain.fromSettings(model: session.model)
        if agent == nil {
            brain.onUsage = { [weak self] u, _, cost in self?.session.usage.add(u, cost: cost); self?.scheduleSave() }
        }
        return Git.cleanCommitMessage(try await brain.oneShot(Git.commitPrompt(diff: diff)))
    }

    // MARK: Items

    func append(_ item: ChatItem) {
        session.items.append(item)
        session.updated = Date()
        scheduleSave()
    }

    private func update(_ id: UUID, _ f: (inout ChatItem) -> Void) {
        guard let i = session.items.lastIndex(where: { $0.id == id }) else { return }
        f(&session.items[i])
    }

    // MARK: Persistence

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        session.updated = Date()
        try? SessionStore.save(session)
    }

    // MARK: AgentHost

    func agentStatus(_ text: String) { status = text }

    func agentThought(_ text: String) {
        guard !text.isEmpty else { return }
        append(ChatItem(kind: .thought, text: text))
    }

    func agentSay(_ text: String, final: Bool) {
        guard !text.isEmpty else { return }
        append(ChatItem(kind: .assistant, text: text, final: final))
    }

    func agentStepBegan(_ id: UUID, tool: String, summary: String) {
        append(ChatItem(id: id, kind: .tool, text: summary, tool: ToolStep(name: tool, summary: summary, status: .running)))
        if tool == "shell" || tool == "start_process" {
            terminal.append(TerminalChunk(stepID: id, title: summary, text: ""))
            if terminal.count > 60 { terminal.removeFirst(terminal.count - 60) }
        }
    }

    func agentStepOutput(_ id: UUID, chunk: String) {
        if let i = terminal.lastIndex(where: { $0.stepID == id }) {
            terminal[i].text += chunk
            if terminal[i].text.count > 200_000 { terminal[i].text = String(terminal[i].text.suffix(150_000)) }
        }
        update(id) { item in
            guard var t = item.tool else { return }
            t.output += chunk
            if t.output.count > 30_000 { t.output = String(t.output.suffix(20_000)) }
            item.tool = t
        }
    }

    func agentStepEnded(_ id: UUID, status: ToolStep.Status, output: String, diffs: [FileDiff], duration: Double) {
        update(id) { item in
            guard var t = item.tool else { return }
            t.status = status
            t.output = Fmt.clip(output, max: 30_000)
            t.diffs = diffs
            t.duration = duration
            item.tool = t
        }
        if let d = diffs.first, status == .ok {
            app?.selectedDiff = d
            app?.previewFile = nil
            app?.revealChanges()
        }
        scheduleSave()
    }

    func agentPermission(_ req: PermissionRequest) async -> PermissionAnswer {
        NSApp?.requestUserAttention(.criticalRequest)
        return await withCheckedContinuation { cont in
            var done = false
            pendingPermission = PendingPermission(request: req) { [weak self] answer in
                guard !done else { return }
                done = true
                self?.pendingPermission = nil
                cont.resume(returning: answer)
            }
        }
    }

    func agentPlan(_ steps: [String]) async -> PlanDecision {
        let card = PlanCard(steps: steps)
        let item = ChatItem(kind: .plan, text: "", plan: card)
        append(item)
        session.plan = card
        session.todos = []
        if app?.showInspector == true { app?.inspectorTab = .todo }
        return await withCheckedContinuation { cont in
            var done = false
            pendingPlan = PendingPlan(itemID: item.id) { [weak self] decision in
                guard !done else { return }
                done = true
                self?.pendingPlan = nil
                self?.update(item.id) { i in
                    switch decision {
                    case .approve, .approveAutoEdits: i.plan?.state = .approved
                    case .cancel: i.plan?.state = .cancelled
                    case .revise: i.plan?.state = .revised
                    }
                }
                if case .approve = decision { self?.session.plan?.state = .approved }
                if case .approveAutoEdits = decision { self?.session.plan?.state = .approved }
                if case .cancel = decision { self?.session.plan?.state = .cancelled }
                cont.resume(returning: decision)
            }
        }
    }

    func agentMilestone(_ index: Int) {
        guard var p = session.plan, index >= 1, index <= p.steps.count else { return }
        for k in 1...index where !p.done.contains(k) { p.done.append(k) }
        session.plan = p
        if let i = session.items.lastIndex(where: { $0.kind == .plan }) { session.items[i].plan?.done = p.done }
        scheduleSave()
    }

    func agentTodos(_ todos: [TodoItem]) {
        session.todos = todos
        scheduleSave()
    }

    func agentAsk(_ question: String) async -> String? {
        append(ChatItem(kind: .assistant, text: question))
        return await withCheckedContinuation { cont in
            var done = false
            pendingQuestion = PendingQuestion(question: question) { [weak self] answer in
                guard !done else { return }
                done = true
                self?.pendingQuestion = nil
                if let answer { self?.append(ChatItem(kind: .user, text: answer)) }
                cont.resume(returning: answer)
            }
        }
    }

    func agentDrainSteering() -> [String] {
        defer { steering = [] }
        return steering
    }

    func agentError(_ text: String) {
        append(ChatItem(kind: .error, text: text))
    }
}
