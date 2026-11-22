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

    private(set) var running = false { didSet { if running != oldValue { app?.workingChanged() } } }
    private(set) var status = ""
    /// The reply as it streams in: the model's reasoning so far (shown under the spinner).
    private(set) var liveText = ""
    private(set) var startedAt: Date?
    var pendingPermission: PendingPermission?
    var pendingPlan: PendingPlan?
    var pendingQuestion: PendingQuestion?
    /// Messages typed while the agent works; delivered with its next observation, or run next if it finishes first.
    private(set) var steering: [String] = []
    private(set) var terminal: [TerminalChunk] = []
    /// Text to put back in the composer (after a rewind).
    var draft: String?
    /// Called when a request finishes (the background queue uses it).
    @ObservationIgnored var onFinish: ((AgentOutcome) -> Void)?
    /// Runs unattended (a queue task or a sub-session): never stops to wait for a plan approval.
    var background = false

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

    /// Tests: supplies the brain instead of the real providers.
    static var brainFactory: ((String?) throws -> Brain)?

    private func makeAgent() throws -> Agent {
        if let agent { return agent }
        let brain = try Self.brainFactory?(session.model) ?? Brain.fromSettings(model: session.model)
        brain.onUsage = { [weak self] u, _, cost in
            self?.session.usage.add(u, cost: cost)
            self?.scheduleSave()
        }
        let ctx = ToolContext(root: root, processes: processes, host: self)
        ctx.browser = app?.browser
        ctx.shellTimeout = AppSettings.shared.shellTimeout
        ctx.todos = session.todos
        let a = Agent(ctx: ctx, brain: brain, extraTools: MCPManager.shared.toolSpecs + (app?.subSessionTools(for: self) ?? []))
        a.toolProvider = { MCPManager.shared.toolSpecs }
        a.messages = session.messages
        a.briefing = session.briefing
        a.briefedTools = session.briefedTools.map(Set.init)
        a.mode = mode
        a.allowedCommands = Set(session.allowedCommands)
        applySettings(a)
        a.onModeChange = { [weak self] m in self?.session.mode = m; self?.scheduleSave() }
        a.onHistory = { [weak self, weak a] in
            guard let self, let a else { return }
            self.session.messages = a.messages
            self.session.briefing = a.briefing
            self.session.briefedTools = a.briefedTools.map { Array($0).sorted() }
            self.session.allowedCommands = Array(a.allowedCommands)
            self.scheduleSave()
        }
        a.onCompacted = { [weak self] _ in self?.session.compactedAt = Date() }
        a.onCheckpoint = { [weak self] cp in
            guard let self else { return }
            if let i = self.session.checkpoints.firstIndex(where: { $0.id == cp.id }) { self.session.checkpoints[i] = cp } else { self.session.checkpoints.append(cp) }
            self.scheduleSave()
        }
        agent = a
        return a
    }

    private func applySettings(_ a: Agent) {
        let s = AppSettings.shared
        a.maxSteps = session.stepLimit ?? s.maxSteps
        a.maxCost = session.costLimit ?? s.maxTaskCost
        a.autoCompactTokens = s.autoCompactTokens
        a.autoVerify = s.autoVerify
        a.selfReview = s.selfReview
        a.streaming = s.streaming
        a.escalationModel = s.escalation(for: model)
        a.exploreModel = s.exploreModel.isEmpty || !s.ready(model: s.exploreModel) ? "" : s.exploreModel
        a.quickModel = s.quickModel.isEmpty || !s.ready(model: s.quickModel) ? "" : s.quickModel
        a.adaptiveEffort = s.adaptiveEffort
        a.prefetch = s.prefetch
        a.prepareWhilePlanning = s.prepareWhilePlanning
        a.lspChecks = s.lspChecks
        a.planNudges = !background
    }

    @ObservationIgnored private var lastWarm = Date.distantPast
    /// The owner started typing: warm the provider's prompt cache so the first turn skips re-reading the prefix.
    func warmCache() {
        guard AppSettings.shared.warmCache, !running, Date().timeIntervalSince(lastWarm) > 45 else { return }
        lastWarm = Date()
        guard let agent = try? makeAgent() else { return }
        applySettings(agent)
        Task { await agent.warmCache() }
    }

    /// Drops the cached agent so new settings (key, effort, MCP tools) apply on the next request.
    func resetAgent() { if !running { agent = nil } }

    // MARK: Sending

    func send(_ raw: String, images: [(Data, String)] = []) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        if images.isEmpty, let (name, args) = SlashCommands.split(text) {
            if running && !["cost", "help", "mode", "queue", "limit"].contains(name) { append(ChatItem(kind: .system, text: "Wait for the current request to finish (or Stop it) before running /\(name).")); return }
            runCommand(name, args: args, raw: text)
            return
        }
        if !Mentions.tokens(in: text).isEmpty && images.isEmpty {
            let last = terminal.last?.text
            let display = text
            Task { [weak self] in
                guard let self else { return }
                let attach = await Mentions.expand(text, root: self.root, lastOutput: last)
                if self.running { self.steering.append(attach + text); self.append(ChatItem(kind: .user, text: display)) }
                else { self.start(goal: attach + text, display: display) }
            }
            noteCorrection(text)
            return
        }
        noteCorrection(text)
        if running {
            steering.append(text)
            append(ChatItem(kind: .user, text: text, images: images.count))
            append(ChatItem(kind: .system, text: "Queued: it reaches the agent with its next step."))
            return
        }
        start(goal: text, display: text, images: images)
    }

    /// A message from another session (a parent or a sub-session): reaches the agent with its next step,
    /// or starts a request when it's idle.
    func deliver(_ text: String, from sender: String) {
        let line = "[Message from \(sender)] \(text)"
        if running {
            steering.append(line)
            append(ChatItem(kind: .user, text: line))
        } else {
            start(goal: line, display: line)
        }
    }

    func start(goal: String, display: String, images: [(Data, String)] = []) {
        if session.worktreeRemoved {
            append(ChatItem(kind: .error, text: "This session's worktree and branch were removed by Worktree cleanup, so it can't run anymore. Fork it to continue the conversation in your project."))
            onFinish?(AgentOutcome(text: "worktree removed", ok: false, steps: 0))
            return
        }
        append(ChatItem(kind: .user, text: display, images: images.count, historyIndex: agent?.messages.count ?? session.messages.count))
        if session.items.filter({ $0.kind == .user }).count == 1 && (session.title == "New session" || session.title.hasPrefix("New session on ")) {
            session.title = Session.title(from: display)
            app?.refreshSessions()
        }
        let agent: Agent
        do { agent = try makeAgent() } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            append(ChatItem(kind: .error, text: msg))
            onFinish?(AgentOutcome(text: msg, ok: false, steps: 0))   // the queue must move on
            return
        }
        agent.mode = mode
        applySettings(agent)
        running = true
        startedAt = Date()
        status = "Thinking"
        let note = images.isEmpty ? "" : "IMAGES THE OWNER PASTED: \(images.count) attached to this message.\n\n"
        task = Task { [weak self] in
            let outcome = await agent.run(goal: goal, images: images, attachmentsNote: note)
            guard let self else { return }
            self.running = false
            self.status = ""
            self.liveText = ""
            self.startedAt = nil
            self.task = nil
            self.pendingPermission = nil
            self.pendingPlan = nil
            self.pendingQuestion = nil
            if !outcome.changedFiles.isEmpty { self.app?.refreshGit() }
            self.saveNow()
            if NSApp != nil && !NSApp.isActive { self.notifyDone(outcome) }
            self.afterRequest(goal: goal, outcome: outcome)
            self.onFinish?(outcome)
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
        let files = o.changedFiles.isEmpty ? "" : " (\(o.changedFiles.count) file\(o.changedFiles.count == 1 ? "" : "s") changed)"
        Notifier.shared.post(id: UUID().uuidString, title: o.ok ? "Done: \(session.title)" : "Stopped: \(session.title)",
                             body: Fmt.line(o.text, 180) + files, category: "done", session: session.id.uuidString)
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
            t += " Context now: about \(Fmt.tokens(max(u.lastPrompt, Compactor.estimateTokens(session.messages, model: model)))) tokens."
            if u.lastCached > 0, u.lastPrompt > 0 { t += " The last request was \(Int((Double(u.lastCached) / Double(u.lastPrompt) * 100).rounded()))% cache hits." }
            if TokenCalibrator.shared.sampleCount(for: model) > 0 { t += " Estimates use \(String(format: "%.1f", TokenCalibrator.shared.ratio(for: model))) characters per token, measured from this model's own usage." }
            append(ChatItem(kind: .system, text: t))
        case "mode":
            let m: PermissionMode? = ["ask": .ask, "edits": .acceptEdits, "accept": .acceptEdits, "acceptedits": .acceptEdits, "auto": .acceptEdits,
                                      "plan": .plan, "bypass": .bypass, "yolo": .bypass][args.lowercased()]
            if let m { mode = m; append(ChatItem(kind: .system, text: "Permission mode: \(m.label).")) }
            else { append(ChatItem(kind: .system, text: "Mode is \(mode.label). Use /mode ask, edits, plan or bypass.")) }
        case "undo":
            undoLast()
        case "limit":
            let parts = args.lowercased().split(separator: " ").map(String.init)
            if parts.first == "off" {
                session.costLimit = 0; session.stepLimit = nil
                append(ChatItem(kind: .system, text: "No cost limit for this session's requests."))
            } else if parts.isEmpty {
                let c = session.costLimit ?? AppSettings.shared.maxTaskCost
                append(ChatItem(kind: .system, text: "Each request stops at \(c > 0 ? Fmt.dollars(c) : "no cost limit") and \(session.stepLimit ?? AppSettings.shared.maxSteps) steps. Use /limit $0.02 40, or /limit off."))
            } else {
                for p in parts {
                    if let v = Double(p.trimmingCharacters(in: CharacterSet(charactersIn: "$"))), p.contains("$") || p.contains(".") { session.costLimit = v }
                    else if let n = Int(p) { session.stepLimit = max(3, n) }
                }
                append(ChatItem(kind: .system, text: "Each request in this session now stops at \((session.costLimit ?? 0) > 0 ? Fmt.dollars(session.costLimit!) : "no cost limit") or \(session.stepLimit ?? AppSettings.shared.maxSteps) steps. Free models never hit the cost limit."))
            }
            scheduleSave()
        case "queue":
            if args.isEmpty { append(ChatItem(kind: .system, text: "Use /queue <task> (or ⌥⏎ in the composer) to add a background task. It runs in its own git worktree.")) }
            else { app?.enqueue(args) }
        case "commit":
            Task { await commitAll() }
        case "pr":
            let goal = "Open a GitHub pull request for the work in this session. If you're on main or master, create a descriptive branch first (git switch -c ...). Commit any uncommitted work with a clear message, then call gh_pr_create with a concise title and a body that says what changed, why, and how it was verified." + (args.isEmpty ? "" : " Notes from the owner: \(args)")
            start(goal: goal, display: raw)
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
        let before = Compactor.estimateTokens(agent.messages, model: model)
        task = Task { [weak self] in
            do {
                try await agent.compact(focus: focus)
                let after = Compactor.estimateTokens(agent.messages, model: model)
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

    // MARK: Learning from the session

    /// A follow-up that sounds like a lasting preference: offer to save it as a project convention.
    private func noteCorrection(_ text: String) {
        guard session.items.contains(where: { $0.kind == .user }), Conventions.looksLikeCorrection(text),
              let brain = try? Brain.fromSettings(model: session.model) else { return }
        brain.onUsage = { [weak self] u, _, cost in self?.session.usage.add(u, cost: cost) }
        Task { [weak self] in
            guard let line = try? await brain.oneShot(Conventions.prompt(text), effort: "low") else { return }
            let clean = Fmt.plain(line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            guard !clean.uppercased().hasPrefix("NONE"), clean.count < 200, let self else { return }
            self.append(ChatItem(kind: .suggestion, text: clean, suggestion: Suggestion(kind: .convention)))
        }
    }

    func acceptSuggestion(_ id: UUID) {
        guard let i = session.items.firstIndex(where: { $0.id == id }), let sug = session.items[i].suggestion else { return }
        switch sug.kind {
        case .convention:
            do {
                let file = try Conventions.save(session.items[i].text, root: root)
                session.items[i].suggestion?.state = .accepted
                append(ChatItem(kind: .system, text: "Saved to \(Paths.display(file, root: root)). New sessions in this project will follow it."))
            } catch { append(ChatItem(kind: .error, text: "Couldn't save the convention: \(error.localizedDescription)")) }
        }
        scheduleSave()
    }

    func dismissSuggestion(_ id: UUID) {
        guard let i = session.items.firstIndex(where: { $0.id == id }) else { return }
        session.items[i].suggestion?.state = .dismissed
        scheduleSave()
    }

    /// Mark a final answer worth saving as a skill when the request did real multi-step work.
    private func afterRequest(goal: String, outcome: AgentOutcome) {
        guard outcome.ok, let finalIdx = session.items.lastIndex(where: { $0.kind == .assistant && $0.final }) else { return }
        let start = session.items[..<finalIdx].lastIndex(where: { $0.kind == .user }) ?? 0
        let steps = session.items[start..<finalIdx].filter { $0.kind == .tool && $0.tool?.status == .ok }.count
        if steps >= 3 { session.items[finalIdx].skillWorthy = true }
    }

    /// "Save as skill": a cheap call turns the request and its steps into .anvil/skills/<name>/SKILL.md.
    func saveSkill(from finalID: UUID) {
        guard let finalIdx = session.items.firstIndex(where: { $0.id == finalID }) else { return }
        let start = session.items[..<finalIdx].lastIndex(where: { $0.kind == .user }) ?? 0
        let request = session.items[start].text
        let steps = session.items[start..<finalIdx].compactMap { $0.kind == .tool ? $0.text : nil }
        let answer = session.items[finalIdx].text
        guard let brain = try? Brain.fromSettings(model: session.model) else { return }
        brain.onUsage = { [weak self] u, _, cost in self?.session.usage.add(u, cost: cost) }
        session.items[finalIdx].skillWorthy = false
        status = "Writing a skill"
        Task { [weak self] in
            guard let self else { return }
            defer { self.status = "" }
            do {
                let raw = try await brain.oneShot(SkillBuilder.prompt(request: request, steps: steps, answer: answer), effort: "low")
                let (body, _, _) = try ActionParser.extractJSON(raw)
                guard let json = ActionParser.parseLenient(body) else { throw ToolFailure("no JSON in the reply") }
                let file = try SkillBuilder.save(json: json, root: self.root)
                self.append(ChatItem(kind: .system, text: "Saved skill \(json["name"]?.string ?? "") to \(Paths.display(file, root: self.root)). It's suggested when a request matches its description."))
            } catch {
                self.append(ChatItem(kind: .error, text: "Couldn't write the skill: \((error as? ToolFailure)?.message ?? error.localizedDescription)"))
            }
        }
    }

    // MARK: Rewind

    /// Can the conversation itself go back to this message (not just the files)?
    func canRewindConversation(_ item: ChatItem) -> Bool {
        guard let h = item.historyIndex, h <= session.messages.count else { return false }
        if let c = session.compactedAt, c > item.date { return false }
        return true
    }

    /// Go back to before `itemID` (a user message): files restored to how they were then, the conversation cut there,
    /// and the message put back in the composer to edit.
    func rewind(to itemID: UUID) {
        guard !running, let idx = session.items.firstIndex(where: { $0.id == itemID }), session.items[idx].kind == .user else { return }
        let item = session.items[idx]
        // Files: undo every request from this one on.
        var restored: [String] = []
        if let first = session.checkpoints.first(where: { $0.created >= item.date && !$0.restored }) {
            restored = (try? Checkpoints.rewind(&session.checkpoints, to: first.id)) ?? []
        }
        // Conversation.
        let conversationOK = canRewindConversation(item)
        if conversationOK, let h = item.historyIndex {
            session.messages = Array(session.messages.prefix(h))
        } else {
            session.messages = []
            session.briefing = ""
        }
        session.items = Array(session.items.prefix(idx))
        if !session.items.contains(where: { $0.kind == .plan }) { session.plan = nil; session.todos = [] }
        agent?.messages = session.messages
        agent?.briefing = session.briefing
        draft = item.text
        var note = "Rewound to before \u{201C}\(Fmt.line(item.text, 60))\u{201D}."
        if !restored.isEmpty { note += " Restored \(restored.count) file(s)." }
        if !conversationOK { note += " The conversation was compacted after that point, so the agent starts fresh (files are restored)." }
        append(ChatItem(kind: .system, text: note))
        app?.refreshGit()
        saveNow()
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

    /// Merges this worktree session's branch into the project's current branch.
    func mergeWorktree() async -> String {
        guard let branch = session.branch else { return "This session isn't on a worktree branch." }
        let st = await Git.status(root)
        if !st.files.isEmpty { return "Commit the session's changes first (\(st.files.count) uncommitted)." }
        let project = URL(fileURLWithPath: session.projectPath)
        if let conflicts = await Git.mergeConflicts(project, branch: branch), !conflicts.isEmpty {
            let msg = "Not merged: \(branch) conflicts with \(session.baseBranch ?? "the project's branch") in \(conflicts.prefix(8).joined(separator: ", "))\(conflicts.count > 8 ? " and \(conflicts.count - 8) more" : ""). Ask the agent here to merge \(session.baseBranch ?? "it") into this branch and resolve the conflicts, then merge again."
            append(ChatItem(kind: .error, text: msg))
            return msg
        }
        let r = await Git.mergeBranch(project, branch: branch, message: "Merge \(branch): \(session.title)")
        app?.refreshGit()
        let msg = r.status == 0 ? "Merged \(branch) into \(session.baseBranch ?? "the project's branch")." : "Merge failed: \(Fmt.line(r.combined, 400))"
        append(ChatItem(kind: r.status == 0 ? .system : .error, text: msg))
        return msg
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

    func agentStream(_ text: String) {
        // Show the reasoning part (before the json block), last line or two.
        let thought = text.components(separatedBy: "```").first ?? ""
        let t = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        liveText = t.count > 220 ? "…" + String(t.suffix(220)) : t
    }

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
            app?.terminals.agentCommand(summary.hasPrefix("$ ") ? String(summary.dropFirst(2)) : summary)
            terminal.append(TerminalChunk(stepID: id, title: summary, text: ""))
            if terminal.count > 60 { terminal.removeFirst(terminal.count - 60) }
        }
    }

    /// A dev server printed its address: show it in the Preview tab.
    private func noticeDevServer(_ chunk: String) {
        guard let app, app.browser.followsDevServer,
              let r = chunk.range(of: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d+[^\s"'\x1b]*"#, options: .regularExpression) else { return }
        let url = String(chunk[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)"))
        guard BrowserController.normalize(url)?.absoluteString != app.browser.url else { return }
        Task { await app.browser.open(url) }
        app.inspectorTab = .preview
        if app.isWide && !app.inspectorDismissed { app.showInspector = true }
    }

    @ObservationIgnored private var reloadWork: DispatchWorkItem?
    /// After an edit, reload a local preview (static servers don't hot-reload).
    private func reloadPreviewSoon() {
        guard let b = app?.browser, b.url.contains("localhost") || b.url.contains("127.0.0.1") else { return }
        reloadWork?.cancel()
        let w = DispatchWorkItem { b.reload() }
        reloadWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func agentStepOutput(_ id: UUID, chunk: String) {
        noticeDevServer(chunk)
        if terminal.contains(where: { $0.stepID == id }) { app?.terminals.agentOutput(chunk) }
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
            if app?.inspectorTab != .preview { app?.revealChanges() }
            reloadPreviewSoon()
        }
        if diffs.isEmpty, status == .ok { noticeDevServer(output) }
        scheduleSave()
    }

    func agentPermission(_ req: PermissionRequest) async -> PermissionAnswer {
        NSApp?.requestUserAttention(.criticalRequest)
        return await withCheckedContinuation { cont in
            var done = false
            let pending = PendingPermission(request: req) { [weak self] answer in
                guard !done else { return }
                done = true
                self?.pendingPermission = nil
                cont.resume(returning: answer)
            }
            pendingPermission = pending
            let noteID = pending.id.uuidString
            let what = req.command.map { "Run: \($0)" } ?? (req.diffs.count == 1 ? "Edit \(req.diffs[0].path) (\(req.diffs[0].statLabel))" : "Apply edits to \(req.diffs.count) files")
            Notifier.shared.post(id: noteID, title: "Anvil needs your approval", body: "\(session.title): \(what)", category: "approval",
                                 session: session.id.uuidString) { action, _ in
                pending.resume(action == "allow" ? .allow : .deny(nil))
            }
            // Answered in the app: drop the notification.
            let original = pending.resume
            pendingPermission = PendingPermission(request: req) { answer in Notifier.shared.withdraw(noteID); original(answer) }
        }
    }

    func agentPlan(_ steps: [String]) async -> PlanDecision {
        var card = PlanCard(steps: steps)
        // Bypass means no prompts: the plan is shown and tracked, but approved right away.
        if mode == .bypass || background { card.state = .approved }
        let item = ChatItem(kind: .plan, text: "", plan: card)
        append(item)
        session.plan = card
        session.todos = []
        if app?.showInspector == true { app?.inspectorTab = .todo }
        if mode == .bypass || background { return .approve }
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
            let noteID = UUID().uuidString
            pendingQuestion = PendingQuestion(question: question) { [weak self] answer in
                guard !done else { return }
                done = true
                Notifier.shared.withdraw(noteID)
                self?.pendingQuestion = nil
                if let answer { self?.append(ChatItem(kind: .user, text: answer)) }
                cont.resume(returning: answer)
            }
            let pending = pendingQuestion
            Notifier.shared.post(id: noteID, title: "Anvil has a question", body: question, category: "question", session: session.id.uuidString) { _, text in
                pending?.resume(text)
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
