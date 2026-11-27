import AppKit

/// `Anvil --headless --project DIR --prompt "..." [--mode bypass|edits|ask|plan] [--model ID] [--resume SESSION-ID] [--max-steps N]`
/// Runs one request without UI, prints the transcript, saves the session (it shows up in the app), exits 0 on success.
/// Permission prompts are answered by --approve (allow everything that asks except dangerous commands).
enum Headless {
    static func value(_ flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// `Anvil --parse FILE`: runs the reply parser on a saved model reply (debugging protocol drift).
    static func parseFile(_ path: String) -> Never {
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        do {
            let r = try ActionParser.parse(raw)
            print("ok: say=\(r.say ?? "-") done=\(r.done) plan=\(r.plan.count) actions=\(r.actions.map(\.tool))")
            exit(0)
        } catch { print("error: \(error)"); exit(1) }
    }

    static func main() {
        // A real AppKit run loop (no Dock icon, no windows) so WebKit works: the agent gets the browser here too.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let code = await run()
            exit(code)
        }
        app.run()
        exit(0)
    }

    static func run() async -> Int32 {
        guard let dir = value("--project"), let prompt = value("--prompt") ?? value("-p") else {
            print("usage: Anvil --headless --project DIR --prompt TEXT [--mode bypass|edits|ask|plan] [--model ID] [--resume ID] [--approve]")
            return 2
        }
        let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).standardizedFileURL
        let modeArg = value("--mode") ?? "edits"
        let mode: PermissionMode = ["bypass": .bypass, "edits": .acceptEdits, "ask": .ask, "plan": .plan][modeArg] ?? .acceptEdits
        var session = value("--resume").flatMap { UUID(uuidString: $0) }.flatMap { SessionStore.load($0, root: root) } ?? Session(projectPath: root.path)
        if session.items.isEmpty { session.title = Session.title(from: prompt) }
        if let m = value("--model") { session.model = m }
        let host = ConsoleHost(approve: CommandLine.arguments.contains("--approve"))
        let processes = ProcessManager()
        let brain: Brain
        do { brain = try Brain.fromSettings(model: session.model) } catch {
            print("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            return 2
        }
        await ModelCatalog.shared.refresh()
        var usage = session.usage
        brain.onUsage = { u, model, cost in
            usage.add(u, cost: cost)
            print("   · \(model): \(u.prompt) in (\(u.cached) cached), \(u.completion) out, \(cost.map(Fmt.dollars) ?? "?")")
        }
        let ctx = ToolContext(root: root, processes: processes, host: host)
        if !CommandLine.arguments.contains("--no-browser") { ctx.browser = BrowserController() }
        MCPManager.shared.start(project: root)
        if CommandLine.arguments.contains("--mcp-status") {
            await MCPManager.shared.waitUntilSettled()
            print(MCPManager.shared.statusLines.joined(separator: "\n"))
            for t in MCPManager.shared.toolSpecs { print("  " + t.catalogLine) }
            MCPManager.shared.stopAll()
            return 0
        }
        let agent = Agent(ctx: ctx, brain: brain)
        agent.toolProvider = { MCPManager.shared.toolSpecs }
        agent.messages = session.messages
        agent.briefing = session.briefing
        agent.mode = mode
        agent.maxSteps = Int(value("--max-steps") ?? "") ?? 60
        let args = CommandLine.arguments
        agent.autoVerify = !args.contains("--no-verify")
        agent.selfReview = !args.contains("--no-review")
        agent.judgeEnabled = !args.contains("--no-judge")   // evals keep the same checks on or off
        agent.streaming = !args.contains("--no-stream")
        agent.escalationModel = args.contains("--no-escalate") ? "" : (value("--escalate") ?? AppSettings.shared.escalation(for: brain.model))
        agent.exploreModel = value("--explore-model") ?? ""
        agent.quickModel = value("--quick-model") ?? ""
        agent.adaptiveEffort = !args.contains("--no-adaptive")
        agent.prefetch = !args.contains("--no-prefetch")
        if args.contains("--brief") {
            let b = await Agent.refreshBrief(root: root, brain: brain.fork(model: brain.model))
            print("  brief: \(b.map { Fmt.line($0.text, 160) } ?? "none")")
        }
        var checkpoints = session.checkpoints
        agent.onCheckpoint = { cp in
            if let i = checkpoints.firstIndex(where: { $0.id == cp.id }) { checkpoints[i] = cp } else { checkpoints.append(cp) }
        }
        host.items.append(ChatItem(kind: .user, text: prompt))
        print("▶︎ \(prompt)\n  project: \(root.path), mode: \(mode.label), model: \(brain.model) (\(Providers.label(for: brain.model))), effort: \(brain.effort)")
        let start = Date()
        let work = Task { await agent.run(goal: prompt) }
        if let t = Double(value("--timeout") ?? "") {
            Task { try? await Task.sleep(for: .seconds(t)); work.cancel() }
        }
        let outcome = await work.value
        processes.stopAll()
        MCPManager.shared.stopAll()
        session.items += host.items
        session.messages = agent.messages
        session.briefing = agent.briefing
        session.checkpoints = checkpoints
        session.usage = usage
        session.todos = ctx.todos
        try? SessionStore.save(session)
        print("\n■ \(outcome.ok ? "done" : "stopped") in \(outcome.steps) steps, \(Int(Date().timeIntervalSince(start)))s, \(Fmt.dollars(usage.cost)) (\(usage.calls) calls)")
        if !outcome.changedFiles.isEmpty { print("  changed: \(outcome.changedFiles.joined(separator: ", "))") }
        print("  session: \(session.id.uuidString)")
        if let path = value("--json-summary") {
            let o: [String: Any] = ["ok": outcome.ok, "steps": outcome.steps, "seconds": Date().timeIntervalSince(start), "cost": usage.cost,
                                    "calls": usage.calls, "prompt": usage.prompt, "completion": usage.completion, "cached": usage.cached,
                                    "model": brain.model, "changed": outcome.changedFiles, "verified": outcome.verifiedBy ?? "", "answer": outcome.text]
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { try? d.write(to: URL(fileURLWithPath: path)) }
        }
        return outcome.ok ? 0 : 1
    }
}

/// Prints agent events to stdout and answers prompts automatically.
final class ConsoleHost: AgentHost {
    let approve: Bool
    var items: [ChatItem] = []
    private var steps: [UUID: ChatItem] = [:]
    init(approve: Bool) { self.approve = approve }

    func agentStatus(_ text: String) {}
    func agentThought(_ text: String) { print("  ∴ \(Fmt.line(text, 220))"); items.append(ChatItem(kind: .thought, text: text)) }
    func agentSay(_ text: String, final: Bool) {
        print(final ? "\n✦ \(text)" : "  » \(text)")
        items.append(ChatItem(kind: .assistant, text: text, final: final))
    }
    func agentStepBegan(_ id: UUID, tool: String, summary: String) {
        steps[id] = ChatItem(id: id, kind: .tool, text: summary, tool: ToolStep(name: tool, summary: summary, status: .running))
    }
    func agentStepOutput(_ id: UUID, chunk: String) {}
    func agentStepEnded(_ id: UUID, status: ToolStep.Status, output: String, diffs: [FileDiff], duration: Double) {
        guard var item = steps.removeValue(forKey: id) else { return }
        item.tool?.status = status
        item.tool?.output = Fmt.clip(output, max: 30_000)
        item.tool?.diffs = diffs
        item.tool?.duration = duration
        items.append(item)
        let mark = status == .ok ? "✓" : status == .denied ? "⊘" : "✗"
        var line = "  \(mark) \(item.text)"
        if !diffs.isEmpty { line += "  [" + diffs.map { "\($0.path) \($0.statLabel)" }.joined(separator: ", ") + "]" }
        if status != .ok { line += "\n      " + Fmt.line(output, 300) }
        print(line)
    }
    func agentPermission(_ req: PermissionRequest) async -> PermissionAnswer {
        let dangerous = req.command.flatMap(Permissions.dangerReason) != nil || req.reason.hasPrefix("writes outside")
        let ok = approve && !dangerous
        print("  ? permission (\(req.reason)) \(req.command ?? req.diffs.map(\.path).joined(separator: ", ")) → \(ok ? "allowed" : "declined")")
        return ok ? .allow : .deny("headless run: not approved")
    }
    func agentPlan(_ steps: [String]) async -> PlanDecision {
        print("  ☐ plan:\n" + steps.enumerated().map { "     \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        items.append(ChatItem(kind: .plan, text: "", plan: PlanCard(steps: steps, state: .approved)))
        return .approve
    }
    func agentMilestone(_ index: Int) { print("  ☑ milestone \(index)") }
    func agentTodos(_ todos: [TodoItem]) { print("  ≡ todos: " + todos.map { ($0.status == .completed ? "[x] " : $0.status == .inProgress ? "[>] " : "[ ] ") + $0.content }.joined(separator: " | ")) }
    func agentAsk(_ question: String) async -> String? { print("  ? \(question) → (no answer in headless mode; use your best judgement)"); return "No answer available (headless run). Use your best judgement and note the assumption." }
    func agentDrainSteering() -> [String] { [] }
    func agentError(_ text: String) { print("  ! \(text)"); items.append(ChatItem(kind: .error, text: text)) }
}
