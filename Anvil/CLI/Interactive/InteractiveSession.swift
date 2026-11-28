import Foundation

/// What the terminal session reacts to. Everything runs on the main actor: keys, ticks, resizes, the end of a run,
/// and the agent's own callbacks (which the agent calls on the main actor too).
enum InteractiveEvent {
    case key(Key)
    case tick
    case resize
    case runFinished(AgentOutcome)
    case quit
}

/// A continuation the agent waits on, resolved at most once (by a key, Esc, or a stop).
@MainActor
final class Pending<T> {
    private var continuation: CheckedContinuation<T, Never>?
    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
    func resolve(_ value: T) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: value)
    }
}

@MainActor
final class PendingPermission {
    let request: PermissionRequest
    let answer: Pending<PermissionAnswer>
    /// After "deny with note": the editor is open for the reason.
    var awaitingNote = false
    init(request: PermissionRequest, answer: Pending<PermissionAnswer>) { self.request = request; self.answer = answer }
}

@MainActor
final class PendingPlan {
    let answer: Pending<PlanDecision>
    /// After "revise": the editor is open for the feedback.
    var revising = false
    init(answer: Pending<PlanDecision>) { self.answer = answer }
}

/// The interactive session: the state, the agent's side (AgentHost) and the input rules. The live region is drawn
/// by `redraw`; finished things are committed to scrollback once. Pure formatting lives in InteractiveFormat.swift.
@MainActor
final class InteractiveSession: AgentHost {
    let term: TUITerminal
    let live: LiveScreen
    let root: URL
    let options: CLIOptions
    private let events: AsyncStream<InteractiveEvent>.Continuation
    private(set) var session: Session
    private(set) var mode: PermissionMode
    private var editor = LineEditor()
    /// Used for the answers to prompts (permission notes, plan feedback, questions) so the typed draft stays put.
    private var noteEditor = LineEditor()
    private var files: [String] = []
    private let processes = ProcessManager()
    private var agent: Agent?
    private var ctx: ToolContext?

    // Run state
    private(set) var running = false
    private var stopping = false
    private var runStart = Date()
    private var costAtStart = 0.0
    private var runTask: Task<Void, Never>?
    private var runningSteps: [(id: UUID, summary: String, output: String)] = []
    private var liveText = ""
    private var status = ""
    private var steering: [String] = []
    private var lastShellOutput: String?
    private var planSteps: [String] = []
    private var lastTodos: [(content: String, status: TodoItem.Status)] = []
    private var stepCount = 0

    // Prompts
    private var pendingPermission: PendingPermission?
    private var pendingPlan: PendingPlan?
    private var pendingAsk: Pending<String?>?

    // Hints and ticks
    private var hintText: String?
    private var quitArmedUntil: Date?
    private var tickCount = 0

    init(term: TUITerminal, live: LiveScreen, root: URL, options: CLIOptions, session: Session,
         events: AsyncStream<InteractiveEvent>.Continuation) {
        self.term = term
        self.live = live
        self.root = root
        self.options = options
        self.session = session
        self.events = events
        // --mode beats the mode a resumed session saved; both beat the app-wide default.
        self.mode = options.mode.map(HeadlessRun.permissionMode) ?? session.mode ?? AppSettings.shared.defaultMode
        let rootCopy = root
        let filesCopy = files
        editor.placeholder = "ask anything · / for commands · @ for files"
        editor.complete = { text, cursor in
            InteractiveCommands.completions(text: text, cursor: cursor, project: rootCopy, files: filesCopy)
        }
        noteEditor.placeholder = ""
    }

    /// The model this session uses (its own, or the app-wide default).
    var model: String { session.model ?? AppSettings.shared.model }

    // MARK: - Start and stop

    /// Loads the history and the project's file list, prints the header line and starts the background services
    /// the headless run also starts.
    func start(resumed: Bool) {
        var history = History()
        history.load(from: Self.historyURL)
        editor.history = history.entries
        files = InteractiveCommands.projectFiles(root: root)
        let rootCopy = root
        let filesCopy = files
        editor.complete = { text, cursor in
            InteractiveCommands.completions(text: text, cursor: cursor, project: rootCopy, files: filesCopy)
        }
        MCPManager.shared.start(project: root)
        Task { await ModelCatalog.shared.refresh() }
        // abbreviatingWithTildeInPath is Apple-only.
        let home = Paths.home.path, place = root.path == home ? "~" : root.path.hasPrefix(home + "/") ? "~" + root.path.dropFirst(home.count) : root.path
        let what = resumed ? "resumed: \(session.title)" : "new session"
        commit([Ansi.dim("anvil \(CLIRouter.version) · \(place) · \(model) · \(mode.short.lowercased()) · \(what)")])
        if resumed { replayTail() }
        redraw()
    }

    /// Stops a run, saves the session and the history, and stops every background thing. Call once, before exit.
    func shutdown() {
        if running { stopRun() }
        runTask?.cancel()
        syncFromAgent()
        saveSession()
        let history = History(entries: editor.history)
        try? history.save(to: Self.historyURL)
        processes.stopAll()
        MCPManager.shared.stopAll()
        ProviderServers.shared.stopAll()
        live.clearLive()
        live.finish()
    }

    static var historyURL: URL { Paths.support.appendingPathComponent("cli-history.jsonl") }

    // MARK: - Ticks and redraws

    func tick() {
        tickCount += 1
        var expired = false
        if let until = quitArmedUntil, Date() >= until {
            quitArmedUntil = nil
            hintText = nil
            expired = true
        }
        // Only the spinner and the hint change on their own; an idle screen is redrawn when something happens.
        if running || hintText != nil || expired { redraw() }
    }

    /// Draws the live region: running steps, the streamed tail, the status line, then the prompt or the editor.
    func redraw() {
        let cols = max(20, term.size().cols - 1)
        var lines: [String] = []
        var cursor: (row: Int, col: Int)?

        for step in runningSteps.suffix(2) {
            lines.append(Ansi.truncate("  " + Ansi.yellow("◦") + " " + step.summary, width: cols))
            if let last = step.output.split(separator: "\n", omittingEmptySubsequences: true).last {
                lines.append(Ansi.dim(Ansi.truncate("    " + String(last), width: cols)))
            }
        }
        if running && !liveText.isEmpty {
            lines += Ansi.wrap(Ansi.dim(liveText), width: cols).suffix(3)
        }

        if running {
            lines.append(StatusLine.working(frame: Spinner.frame(at: tickCount), elapsed: Date().timeIntervalSince(runStart),
                                            steps: stepCount, cost: session.usage.cost - costAtStart,
                                            contextPercent: contextPercent(), status: status, mode: mode, width: cols))
        } else {
            lines.append(StatusLine.idle(model: model, mode: mode, hint: hintText, width: cols))
        }

        if let p = pendingPermission {
            let isCommand = p.request.command != nil
            let subject = p.request.command.map { "$ " + $0 } ?? p.request.diffs.map(\.path).joined(separator: ", ")
            lines.append(Ansi.truncate(Ansi.bold(Ansi.yellow("? ")) + p.request.reason + (subject.isEmpty ? "" : ": " + subject), width: cols))
            if p.awaitingNote {
                cursor = appendEditor(&lines, editor: noteEditor, prompt: "why? ", continuation: "     ", width: cols)
            } else {
                lines.append(Ansi.dim(PermissionKeys.choiceLine(isCommand: isCommand)))
            }
        } else if let p = pendingPlan, p.revising {
            cursor = appendEditor(&lines, editor: noteEditor, prompt: "revise › ", continuation: "  ", width: cols)
        } else if pendingPlan != nil {
            lines.append(Ansi.dim("[y] approve  [e] approve and auto-accept edits  [r] revise  [n] cancel"))
        } else if pendingAsk != nil {
            cursor = appendEditor(&lines, editor: noteEditor, prompt: "? ", continuation: "  ", width: cols)
        } else {
            editor.placeholder = running ? "type to queue a message · Esc stops" : "ask anything · / for commands · @ for files"
            cursor = appendEditor(&lines, editor: editor, prompt: "› ", continuation: "  ", width: cols)
            if !editor.candidates.isEmpty {
                lines.append(Ansi.dim(Ansi.truncate(editor.candidates.prefix(8).joined(separator: "  "), width: cols)))
            }
        }
        live.setLiveThrottled(lines, cursor: cursor)
    }

    /// Appends an editor's rows and returns where its cursor sits in the whole region.
    private func appendEditor(_ lines: inout [String], editor e: LineEditor, prompt: String, continuation: String, width: Int)
        -> (row: Int, col: Int) {
        let base = lines.count
        let box = e.render(width: width, prompt: prompt, continuation: continuation)
        lines += box.lines
        return (base + box.cursorRow, box.cursorCol)
    }

    private func contextPercent() -> Int? {
        guard let window = ModelCatalog.shared.info(model)?.contextTokens, window > 0, session.usage.lastPrompt > 0 else { return nil }
        return min(999, session.usage.lastPrompt * 100 / window)
    }

    // MARK: - Keys

    /// Handles one key. Returns false when the session should end.
    func handle(_ key: Key) -> Bool {
        if let p = pendingPermission {
            handlePermissionKey(p, key)
            redraw()
            return true
        }
        if let p = pendingPlan {
            handlePlanKey(p, key)
            redraw()
            return true
        }
        if let q = pendingAsk {
            let k = key == .ctrl("c") ? Key.escape : key
            switch noteEditor.handle(k) {
            case .submit(let text):
                pendingAsk = nil
                commit([Ansi.dim("  › " + text)])
                q.resolve(text)
            case .eof:
                pendingAsk = nil
                q.resolve(nil)
            default:
                if k == .escape {
                    pendingAsk = nil
                    q.resolve(nil)
                }
            }
            redraw()
            return true
        }
        if running {
            switch key {
            case .escape, .ctrl("c"):
                stopRun()
            case .shiftTab:
                cycleMode()
            default:
                if case .submit(let text) = editor.handle(key) { runningSubmit(text) }
            }
            redraw()
            return true
        }
        if key == .shiftTab {
            cycleMode()
            redraw()
            return true
        }
        if key == .ctrl("c") && editor.isEmpty {
            return exitOrArm()
        }
        switch editor.handle(key) {
        case .submit(let text):
            submitIdle(text)
        case .eof:
            return false
        case .cancel:
            return exitOrArm()
        case .changed, .none:
            break
        }
        redraw()
        return true
    }

    private func handlePermissionKey(_ p: PendingPermission, _ key: Key) {
        if p.awaitingNote {
            if key == .escape || key == .ctrl("c") {
                resolvePermission(p, .deny(nil))
                return
            }
            if case .submit(let text) = noteEditor.handle(key) {
                resolvePermission(p, .deny(text.isEmpty ? nil : text))
            }
            return
        }
        let k = key == .ctrl("c") ? Key.escape : key
        switch PermissionKeys.action(for: k, isCommand: p.request.command != nil) {
        case .answer(let answer): resolvePermission(p, answer)
        case .denyWithNote: p.awaitingNote = true
        case .ignore: break
        }
    }

    private func resolvePermission(_ p: PendingPermission, _ answer: PermissionAnswer) {
        pendingPermission = nil
        noteEditor = LineEditor()
        if answer == .allowSession, p.request.command == nil { setMode(.acceptEdits, announce: true) }
        p.answer.resolve(answer)
    }

    private func handlePlanKey(_ p: PendingPlan, _ key: Key) {
        if p.revising {
            if key == .escape {
                p.revising = false
                return
            }
            if case .submit(let text) = noteEditor.handle(key) {
                pendingPlan = nil
                noteEditor = LineEditor()
                p.answer.resolve(.revise(text))
            }
            return
        }
        if key == .escape || key == .ctrl("c") {
            pendingPlan = nil
            p.answer.resolve(.cancel)
            return
        }
        guard case .char(let c) = key else { return }
        switch String(c).lowercased() {
        case "y":
            pendingPlan = nil
            p.answer.resolve(.approve)
        case "e":
            setMode(.acceptEdits, announce: true)
            pendingPlan = nil
            p.answer.resolve(.approveAutoEdits)
        case "r":
            p.revising = true
        case "n":
            pendingPlan = nil
            p.answer.resolve(.cancel)
        default:
            break
        }
    }

    private func exitOrArm() -> Bool {
        if let until = quitArmedUntil, Date() < until { return false }
        quitArmedUntil = Date().addingTimeInterval(2)
        hintText = "press Ctrl-C again to exit"
        return true
    }

    private func cycleMode() {
        let order: [PermissionMode] = [.ask, .acceptEdits, .plan, .bypass]
        let next = order[((order.firstIndex(of: mode) ?? 0) + 1) % order.count]
        setMode(next, announce: false)
    }

    func setMode(_ m: PermissionMode, announce: Bool) {
        mode = m
        session.mode = m
        agent?.mode = m
        if announce { commit([Ansi.dim("  mode: \(m.label)")]) }
    }

    // MARK: - Submitting

    /// Input while idle: a command, a request (with @-mentions expanded), or nothing.
    private func submitIdle(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let (name, args) = SlashCommands.split(text) {
            command(name, args: args, raw: text)
            return
        }
        if !Mentions.tokens(in: text).isEmpty {
            let last = lastShellOutput
            Task { [weak self] in
                guard let self else { return }
                let attach = await Mentions.expand(text, root: self.root, lastOutput: last)
                self.submitRequest(goal: attach + text, display: text)
            }
            return
        }
        submitRequest(goal: text, display: text)
    }

    /// Input while a run is going: a few commands run now, a message queues as steering, anything else waits.
    private func runningSubmit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let (name, args) = SlashCommands.split(text) {
            if ["help", "mode", "cost", "exit", "quit"].contains(name) {
                command(name, args: args, raw: text)
            } else {
                commit([Ansi.dim("Wait for the current request to finish (or Esc to stop) before /\(name).")])
            }
            return
        }
        steering.append(text)
        commit([Ansi.dim("  ↳ queued: " + Fmt.line(text, 200))])
    }

    /// Starts a request. The user's line is committed; the agent's work streams into the live region.
    func submitRequest(goal: String, display: String) {
        if running {
            steering.append(goal)
            commit([Ansi.dim("  ↳ queued: " + Fmt.line(display, 200))])
            return
        }
        if !session.items.contains(where: { $0.kind == .user }) { session.title = Session.title(from: display) }
        session.items.append(ChatItem(kind: .user, text: display))
        commit(["", Ansi.bold("› " + display)])
        startWork { agent in await agent.run(goal: goal) }
    }

    /// Runs `work` on the agent in its own task. The end comes back as `.runFinished`.
    private func startWork(_ work: @escaping (Agent) async -> AgentOutcome) {
        guard let agent = ensureAgent() else { return }
        running = true
        stopping = false
        runStart = Date()
        costAtStart = session.usage.cost
        stepCount = 0
        runningSteps = []
        liveText = ""
        status = "Thinking"
        agent.mode = mode
        let events = self.events
        runTask = Task {
            let outcome = await work(agent)
            events.yield(.runFinished(outcome))
        }
        redraw()
    }

    /// Stops the run: pending prompts get their safe answers first, so the agent is never left waiting.
    func stopRun() {
        guard running else { return }
        stopping = true
        steering = []
        if let p = pendingPermission { pendingPermission = nil; p.answer.resolve(.deny("stopped")) }
        if let p = pendingPlan { pendingPlan = nil; p.answer.resolve(.cancel) }
        if let q = pendingAsk { pendingAsk = nil; q.resolve(nil) }
        runTask?.cancel()
    }

    /// The end of a run: the summary line, the saved session, and any queued messages as the next request.
    func finishRun(_ outcome: AgentOutcome) {
        running = false
        runTask = nil
        status = ""
        liveText = ""
        runningSteps = []
        syncFromAgent()
        let cost = session.usage.cost - costAtStart
        let seconds = Spinner.elapsed(Date().timeIntervalSince(runStart))
        let detail = "\(seconds) · \(outcome.steps) step\(outcome.steps == 1 ? "" : "s") · \(Fmt.dollars(cost))"
        if stopping {
            commit([Ansi.dim("stopped after " + detail)])
        } else if outcome.ok {
            commit([Ansi.dim("done in " + detail)])
        } else {
            commit([Ansi.dim("stopped: " + Fmt.line(outcome.text, 160) + " (" + detail + ")")])
        }
        stopping = false
        saveSession()
        if !steering.isEmpty {
            let next = steering.joined(separator: "\n\n")
            steering = []
            submitRequest(goal: next, display: "(continuing with your queued message)")
        }
        redraw()
    }

    // MARK: - Agent

    /// The agent for this session, built on first use and rebuilt after /clear, /resume or /model.
    private func ensureAgent() -> Agent? {
        if let agent { return agent }
        do {
            let brain = try Brain.fromSettings(model: session.model)
            brain.onUsage = { [weak self] u, _, cost in
                self?.session.usage.add(u, cost: cost)
            }
            let c = ToolContext(root: root, processes: processes, host: self)
            c.shellTimeout = AppSettings.shared.shellTimeout
            c.todos = session.todos
            let a = Agent(ctx: c, brain: brain)
            AgentSetup.configure(a, options: options, mode: mode)
            a.messages = session.messages
            a.briefing = session.briefing
            a.allowedCommands = Set(session.allowedCommands)
            // The agent switches modes itself (plan approved, auto-accept chosen): follow it, or the next request undoes it.
            a.onModeChange = { [weak self] m in
                guard let self else { return }
                self.mode = m
                self.session.mode = m
                self.redraw()
            }
            a.onCheckpoint = { [weak self] cp in
                guard let self else { return }
                if let i = self.session.checkpoints.firstIndex(where: { $0.id == cp.id }) {
                    self.session.checkpoints[i] = cp
                } else {
                    self.session.checkpoints.append(cp)
                }
            }
            a.onCompacted = { [weak self] _ in self?.session.compactedAt = Date() }
            a.onModelFallback = { [weak self] m in self?.session.model = m }
            agent = a
            ctx = c
            return a
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            commit([Ansi.red("  ! " + msg)])
            return nil
        }
    }

    /// Copies the agent's conversation and todos into the session (called before saving and rebuilding).
    private func syncFromAgent() {
        if let a = agent {
            session.messages = a.messages
            session.briefing = a.briefing
            session.allowedCommands = Array(a.allowedCommands)
        }
        if let c = ctx { session.todos = c.todos }
    }

    func saveSession() {
        guard !session.items.isEmpty || !session.messages.isEmpty else { return }
        syncFromAgent()
        session.updated = Date()
        try? SessionStore.save(session)
    }

    // MARK: - Slash commands

    private func command(_ name: String, args: String, raw: String) {
        switch name {
        case "help":
            commit(InteractiveCommands.helpText(project: root).components(separatedBy: "\n").map { Ansi.dim($0) })
        case "mode":
            let map: [String: PermissionMode] = ["ask": .ask, "edits": .acceptEdits, "accept": .acceptEdits, "auto": .acceptEdits,
                                                 "plan": .plan, "bypass": .bypass, "yolo": .bypass]
            if args.isEmpty {
                commit([Ansi.dim("Mode is \(mode.label). Use /mode ask, edits, plan or bypass.")])
            } else if let m = map[args.lowercased()] {
                setMode(m, announce: true)
            } else {
                commit([Ansi.dim("Unknown mode \(args). Use /mode ask, edits, plan or bypass.")])
            }
        case "model":
            cmdModel(args)
        case "cost":
            commit([Ansi.dim(costText())])
        case "undo":
            undo()
        case "clear":
            guard !running else { return }
            saveSession()
            let kept = session.model
            session = Session(projectPath: root.path)
            session.model = kept
            agent = nil
            ctx = nil
            commit(["", Ansi.dim("── new session ──")])
        case "sessions":
            let rows = SessionStore.list(root: root).prefix(10)
            if rows.isEmpty { commit([Ansi.dim("No sessions in this project yet.")]); return }
            commit(rows.map { Ansi.dim("  \($0.id.uuidString.prefix(8))  \(Fmt.line($0.title, 60))  \(Fmt.dollars($0.cost))") })
        case "resume":
            cmdResume(args)
        case "compact":
            cmdCompact(args)
        case "init":
            guard !running else { return }
            let extra = args.isEmpty ? "" : "\n\nExtra guidance: \(args)"
            submitRequest(goal: ProjectContext.initPrompt + extra, display: raw)
        case "exit", "quit":
            events.yield(.quit)
        default:
            if let c = SlashCommands.custom(project: root).first(where: { $0.name == name }) {
                submitRequest(goal: c.expand(args), display: raw)
            } else {
                commit([Ansi.red("Unknown command /\(name). Type /help for the list.")])
            }
        }
    }

    private func costText() -> String {
        let u = session.usage
        var t = "This session: \(Fmt.dollars(u.cost)) over \(u.calls) model calls. \(Fmt.tokens(u.prompt)) prompt tokens (\(Fmt.tokens(u.cached)) from cache), \(Fmt.tokens(u.completion)) output."
        if let p = contextPercent() { t += " Context is about \(p)% full." }
        if u.lastCached > 0, u.lastPrompt > 0 { t += " The last request was \(Int((Double(u.lastCached) / Double(u.lastPrompt) * 100).rounded()))% cache hits." }
        return t
    }

    private func cmdModel(_ args: String) {
        if args.isEmpty {
            let choices = ModelCatalog.shared.choices
            if choices.isEmpty { commit([Ansi.dim("No models are listed yet. Run a request once, or check `anvil providers`.")]); return }
            let width = choices.map { $0.id.count }.max() ?? 0
            var lines = choices.map { c -> String in
                let mark = c.id == model ? "*" : " "
                let detail = c.detail.isEmpty ? "" : "  " + c.detail
                return Ansi.dim("\(mark) " + c.id.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + Providers.label(for: c.id) + detail)
            }
            lines.append(Ansi.dim("* = this session's model. Switch with /model ID."))
            commit(lines)
            return
        }
        guard !running else { return }
        syncFromAgent()
        session.model = args
        agent = nil
        ctx = nil
        commit([Ansi.dim("This session now uses \(args).")])
    }

    private func undo() {
        guard !running else { return }
        guard let last = session.checkpoints.last(where: { !$0.restored }) else {
            commit([Ansi.dim("No file changes to undo.")])
            return
        }
        do {
            let paths = try Checkpoints.rewind(&session.checkpoints, to: last.id)
            if paths.isEmpty {
                commit([Ansi.dim("Nothing to restore.")])
                return
            }
            let shown = paths.map { Paths.display(URL(fileURLWithPath: $0), root: root) }
            commit([Ansi.dim("Restored \(paths.count) file(s): " + shown.joined(separator: ", "))])
            if let a = agent, !a.messages.isEmpty {
                let note = "(Note: the owner undid your earlier file changes to: \(shown.joined(separator: ", ")). Re-read files before editing them.)"
                a.messages.append(.user(note))
                a.messages.append(.assistant("Noted.\n```json\n{\"say\": \"Noted.\", \"actions\": [], \"done\": true}\n```"))
            }
            saveSession()
        } catch {
            commit([Ansi.red("Undo failed: \(error.localizedDescription)")])
        }
    }

    private func cmdResume(_ args: String) {
        guard !running else { return }
        guard !args.isEmpty else { commit([Ansi.dim("Use /resume ID. See /sessions for the IDs.")]); return }
        guard let full = SessionLookup.find(args, root: root), let loaded = SessionStore.load(full, root: root) else {
            commit([Ansi.red("No session starts with \(args). See /sessions.")])
            return
        }
        saveSession()
        session = loaded
        agent = nil
        ctx = nil
        mode = loaded.mode ?? mode
        commit(["", Ansi.dim("── resumed: \(loaded.title) ──")])
        replayTail()
    }

    /// Shows the last few messages of the session, so a resumed conversation has some context on screen.
    private func replayTail() {
        for item in session.items.suffix(6) {
            switch item.kind {
            case .user: commit([Ansi.bold("› " + Fmt.line(item.text, 300))])
            case .assistant: commit([Ansi.dim("  » " + Fmt.line(item.text, 300))])
            default: break
            }
        }
    }

    private func cmdCompact(_ focus: String) {
        guard !running, let a = ensureAgent() else { return }
        guard a.messages.count >= 2 else { commit([Ansi.dim("Nothing to compact yet.")]); return }
        let before = Compactor.estimateTokens(a.messages, model: model)
        let f = focus.isEmpty ? nil : focus
        startWork { agent in
            do {
                try await agent.compact(focus: f)
                let after = Compactor.estimateTokens(agent.messages, model: self.model)
                return AgentOutcome(text: "Compacted the conversation: about \(Fmt.tokens(before)) to \(Fmt.tokens(after)) tokens.", ok: true, steps: 0)
            } catch {
                return AgentOutcome(text: "Compacting failed: \(error.localizedDescription)", ok: false, steps: 0)
            }
        }
    }

    // MARK: - AgentHost

    func agentStatus(_ text: String) {
        status = text
        if running { redraw() }
    }

    func agentThought(_ text: String) {
        guard !text.isEmpty else { return }
        commit([Ansi.dim(Ansi.truncate("  ∴ " + Fmt.line(text, 400), width: max(20, term.size().cols - 1)))])
    }

    func agentSay(_ text: String, final: Bool) {
        guard !text.isEmpty else { return }
        liveText = ""
        if final {
            session.items.append(ChatItem(kind: .assistant, text: text, final: true))
            commit([""] + MarkdownLite.render(text, width: max(20, term.size().cols - 1)))
        } else {
            commit([Ansi.dim("  » " + text)])
        }
    }

    /// The reply as it streams: the reasoning before any code block, last lines only.
    func agentStream(_ text: String) {
        let thought = text.components(separatedBy: "```").first ?? ""
        let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        liveText = trimmed.count > 800 ? "…" + String(trimmed.suffix(800)) : trimmed
        if running { redraw() }
    }

    func agentStepBegan(_ id: UUID, tool: String, summary: String) {
        stepCount += 1
        runningSteps.append((id: id, summary: summary, output: ""))
        redraw()
    }

    func agentStepOutput(_ id: UUID, chunk: String) {
        guard let i = runningSteps.firstIndex(where: { $0.id == id }) else { return }
        var out = runningSteps[i].output + chunk
        if out.count > 2000 { out = String(out.suffix(1500)) }
        runningSteps[i].output = out
        redraw()
    }

    func agentStepEnded(_ id: UUID, status stepStatus: ToolStep.Status, output: String, diffs: [FileDiff], duration: Double) {
        let summary = runningSteps.first(where: { $0.id == id })?.summary ?? "step"
        runningSteps.removeAll { $0.id == id }
        // The last shell command's output is what `@last-output` attaches.
        if summary.hasPrefix("$ "), !output.isEmpty {
            lastShellOutput = Fmt.clip(output, max: 12_000)
        }
        let mark: String
        switch stepStatus {
        case .ok: mark = Ansi.green("✓")
        case .denied: mark = Ansi.yellow("⊘")
        default: mark = Ansi.red("✗")
        }
        var line = "  " + mark + " " + summary
        if !diffs.isEmpty {
            line += Ansi.dim("  [" + diffs.map { "\($0.path) \($0.statLabel)" }.joined(separator: ", ") + "]")
        }
        var rows = [line]
        if stepStatus == .failed || stepStatus == .running {
            for l in output.split(separator: "\n", omittingEmptySubsequences: true).prefix(2) {
                rows.append(Ansi.dim("      " + Fmt.line(String(l), 300)))
            }
        }
        commit(rows)
        session.items.append(ChatItem(kind: .tool, text: summary,
                                      tool: ToolStep(name: "", summary: summary, status: stepStatus, output: Fmt.clip(output, max: 4000), diffs: diffs, duration: duration)))
        redraw()
    }

    func agentPermission(_ req: PermissionRequest) async -> PermissionAnswer {
        if stopping { return .deny("stopped") }
        // Edits: the diff is committed first, so the owner sees what the prompt is about.
        for d in req.diffs {
            commit(DiffView.lines(d, color: Ansi.colorEnabled))
        }
        return await withCheckedContinuation { cont in
            pendingPermission = PendingPermission(request: req, answer: Pending(cont))
            noteEditor = LineEditor()
            redraw()
        }
    }

    func agentPlan(_ steps: [String]) async -> PlanDecision {
        if stopping { return .cancel }
        planSteps = steps
        commit(["  ☐ plan:"] + steps.enumerated().map { "     \($0.offset + 1). \($0.element)" })
        if mode == .bypass { return .approve }
        return await withCheckedContinuation { cont in
            pendingPlan = PendingPlan(answer: Pending(cont))
            redraw()
        }
    }

    func agentMilestone(_ index: Int) {
        let text = planSteps.indices.contains(index - 1) ? planSteps[index - 1] : "milestone \(index)"
        commit([Ansi.dim("  ☑ " + Fmt.line(text, 200))])
    }

    func agentTodos(_ todos: [TodoItem]) {
        let now = todos.map { (content: $0.content, status: $0.status) }
        guard now.count != lastTodos.count || zip(now, lastTodos).contains(where: { $0.content != $1.content || $0.status != $1.status }) else { return }
        lastTodos = now
        guard !now.isEmpty else { return }
        commit(todos.map { t -> String in
            let glyph = t.status == .completed ? "☑" : t.status == .inProgress ? "◐" : "☐"
            return Ansi.dim("  \(glyph) " + Fmt.line(t.content, 200))
        })
    }

    func agentAsk(_ question: String) async -> String? {
        if stopping { return nil }
        commit([Ansi.bold("  ? " + Fmt.line(question, 400))])
        return await withCheckedContinuation { cont in
            pendingAsk = Pending(cont)
            noteEditor = LineEditor()
            redraw()
        }
    }

    func agentDrainSteering() -> [String] {
        defer { steering = [] }
        return steering
    }

    func agentError(_ text: String) {
        commit([Ansi.red("  ! " + text)])
        session.items.append(ChatItem(kind: .error, text: text))
    }

    // MARK: - Output

    /// Commits finished lines to scrollback, then redraws the live region below them.
    private func commit(_ lines: [String]) {
        live.commit(lines)
    }
}
