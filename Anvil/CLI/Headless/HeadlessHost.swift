import Foundation

/// The agent's side of a headless run: progress to stderr (text and json), every event as a JSON line on stdout
/// (stream-json), and answers to permission and question prompts without a person.
final class HeadlessHost: AgentHost {
    let format: OutputFormat
    let quiet: Bool
    let approve: Bool
    /// The chat items of this run, saved with the session so the app shows them.
    var items: [ChatItem] = []
    /// The last error the agent reported that is a setup or provider failure (see HeadlessExit.classify).
    private(set) var failure: FailureKind?
    private(set) var failureText: String?
    private var steps: [UUID: ChatItem] = [:]
    /// The reply text streamed so far, to turn cumulative text into the new part only.
    private var streamed = ""
    /// Where stream-json lines go (stdout by default; tests collect them here).
    var sink: ((String) -> Void)?

    init(format: OutputFormat, quiet: Bool, approve: Bool) {
        self.format = format
        self.quiet = quiet
        self.approve = approve
    }

    // MARK: Output

    /// A progress line on stderr, unless --quiet.
    func progress(_ line: String) {
        guard !quiet else { return }
        HeadlessHost.stderr(line)
    }

    static func stderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// One event on stdout, only for --output stream-json.
    private func event(_ type: String, _ fields: [String: Any] = [:]) {
        guard format == .streamJSON else { return }
        var o = fields
        o["type"] = type
        emit(JSONLine.encode(o))
    }

    func emit(_ line: String) {
        if let sink { sink(line) } else { print(line) }
    }

    // MARK: AgentHost

    func agentStatus(_ text: String) {
        event("status", ["text": text])
    }

    func agentThought(_ text: String) {
        event("thought", ["text": text])
        progress("  ∴ \(Fmt.line(text, 220))")
        items.append(ChatItem(kind: .thought, text: text))
    }

    func agentSay(_ text: String, final: Bool) {
        event("say", ["text": text, "final": final])
        if !final { progress("  » \(Fmt.line(text, 220))") }
        items.append(ChatItem(kind: .assistant, text: text, final: final))
    }

    /// Streams the reply. The Brain passes the text so far, so only the new part is sent as an event.
    func agentStream(_ text: String) {
        if text.isEmpty { streamed = ""; return }
        let delta: String
        if !streamed.isEmpty, text.hasPrefix(streamed) {
            delta = String(text.dropFirst(streamed.count))
        } else {
            delta = text
        }
        streamed = text
        if !delta.isEmpty { event("stream", ["text": delta]) }
    }

    func agentStepBegan(_ id: UUID, tool: String, summary: String) {
        event("step_begin", ["id": id.uuidString, "tool": tool, "summary": summary])
        steps[id] = ChatItem(id: id, kind: .tool, text: summary, tool: ToolStep(name: tool, summary: summary, status: .running))
    }

    func agentStepOutput(_ id: UUID, chunk: String) {
        event("step_output", ["id": id.uuidString, "text": chunk])
    }

    func agentStepEnded(_ id: UUID, status: ToolStep.Status, output: String, diffs: [FileDiff], duration: Double) {
        let diffList: [[String: Any]] = diffs.map { ["path": $0.path, "added": $0.added, "removed": $0.removed, "new": $0.isNew, "deleted": $0.isDeleted] }
        event("step_end", ["id": id.uuidString, "status": status.rawValue, "output": Fmt.clip(output, max: 30_000),
                           "diffs": diffList, "seconds": JSONLine.finite(duration)])
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
        progress(line)
    }

    func agentPermission(_ req: PermissionRequest) async -> PermissionAnswer {
        let dangerous = req.command.flatMap(Permissions.dangerReason) != nil || req.reason.hasPrefix("writes outside")
        let ok = approve && !dangerous
        let what = req.command ?? req.diffs.map(\.path).joined(separator: ", ")
        event("permission", ["tool": req.tool, "reason": req.reason, "subject": what, "allowed": ok])
        progress("  ? permission (\(req.reason)) \(what) → \(ok ? "allowed" : "declined")")
        return ok ? .allow : .deny("headless run: not approved (use --approve or --mode)")
    }

    func agentPlan(_ steps: [String]) async -> PlanDecision {
        event("plan", ["steps": steps])
        progress("  ☐ plan:\n" + steps.enumerated().map { "     \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        items.append(ChatItem(kind: .plan, text: "", plan: PlanCard(steps: steps, state: .approved)))
        return .approve
    }

    func agentMilestone(_ index: Int) {
        event("status", ["text": "milestone \(index)"])
        progress("  ☑ milestone \(index)")
    }

    func agentTodos(_ todos: [TodoItem]) {
        let list: [[String: Any]] = todos.map { ["content": $0.content, "status": $0.status.rawValue] }
        event("todos", ["items": list])
        progress("  ≡ todos: " + todos.map { ($0.status == .completed ? "[x] " : $0.status == .inProgress ? "[>] " : "[ ] ") + $0.content }.joined(separator: " | "))
    }

    func agentAsk(_ question: String) async -> String? {
        event("ask", ["question": question, "answer": "none (headless run)"])
        progress("  ? \(question) → (no answer in headless mode; use your best judgement)")
        return "No answer available (headless run). Use your best judgement and note the assumption."
    }

    func agentDrainSteering() -> [String] { [] }

    func agentError(_ text: String) {
        event("error", ["text": text])
        progress("  ! \(text)")
        items.append(ChatItem(kind: .error, text: text))
        if let kind = HeadlessExit.classify(text) {
            failure = kind
            failureText = text
        }
    }
}
