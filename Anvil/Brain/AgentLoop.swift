import Foundation

struct AgentOutcome {
    var text: String
    var ok: Bool
    var steps: Int
    var changedFiles: [String] = []
}

/// Observe, think, act loop over the text action protocol (ported from Peep, specialised for coding).
final class Agent {
    let ctx: ToolContext
    var brain: Brain
    private(set) var tools: [String: ToolSpec] = [:]
    private var ordered: [ToolSpec] = []

    /// The model conversation. Saved with the session, so it can be resumed.
    var messages: [ChatMessage] = []
    /// The fixed part of the first turn (role, rules, catalog, project context), reused when compacting.
    var briefing = ""
    var mode: PermissionMode = .ask { didSet { if mode != oldValue { onModeChange?(mode) } } }
    var allowedCommands = Set<String>()
    var maxSteps = 80
    var autoCompactTokens = 160_000
    /// A turn that never reached the model (network failure), re-sent with the next request.
    private var unsent: String?
    private var checkpoint = Checkpoint(label: "")

    var onModeChange: ((PermissionMode) -> Void)?
    var onCheckpoint: ((Checkpoint) -> Void)?
    /// Called whenever `messages` changes (persist the session).
    var onHistory: (() -> Void)?
    var onCompacted: ((String) -> Void)?

    init(ctx: ToolContext, brain: Brain, extraTools: [ToolSpec] = []) {
        self.ctx = ctx
        self.brain = brain
        register(FileTools.all() + ShellTools.all() + WorkTools.all() + extraTools)
    }

    var host: AgentHost? { ctx.host }

    func register(_ specs: [ToolSpec]) {
        for t in specs { tools[t.name] = t; ordered.removeAll { $0.name == t.name }; ordered.append(t) }
    }

    var catalog: String {
        var out: [String] = []
        for g in ToolGroup.allCases {
            let items = ordered.filter { $0.group == g }
            guard !items.isEmpty else { continue }
            out.append("[\(g.rawValue)]")
            out += items.map(\.catalogLine)
        }
        return out.joined(separator: "\n")
    }

    func projectInfo() async -> PromptBuilder.ProjectInfo {
        let root = ctx.root
        let skills = SkillLibrary.all(project: root)
        return PromptBuilder.ProjectInfo(root: root, git: await Git.status(root), layout: ProjectContext.layout(root),
                                         memory: ProjectContext.memory(root), skills: [], skillCount: skills.count)
    }

    // MARK: Run

    func run(goal: String, images: [(Data, String)] = [], attachmentsNote: String = "") async -> AgentOutcome {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Anvil is working on a task")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let taskStart = Date()
        checkpoint = Checkpoint(label: Fmt.line(goal, 80))

        var intro: String
        if messages.isEmpty {
            var info = await projectInfo()
            info.skills = SkillLibrary.matching(goal, project: ctx.root)
            briefing = PromptBuilder.fixed(catalog: catalog) + PromptBuilder.projectContext(info)
            intro = briefing + PromptBuilder.request(goal, attachments: attachmentsNote)
        } else {
            intro = PromptBuilder.followUp(goal, attachments: attachmentsNote)
        }
        var userText = (unsent.map { $0 + "\n\n" } ?? "") + intro + PromptBuilder.modeNote(mode) + PromptBuilder.formatReminder
        unsent = nil
        var pendingImages = images
        var parseFailures = 0
        var planApproved = false
        var planShown = false
        var lastMode = mode
        let maxSteps = max(3, self.maxSteps)

        for step in 1...maxSteps {
            if Task.isCancelled { return finish("Stopped.", ok: false, steps: step) }
            host?.agentStatus(step == 1 ? "Thinking" : "Thinking (step \(step))")

            // Compact before the context gets too big (keeps the pending turn).
            if Compactor.shouldCompact(messages, limit: autoCompactTokens) {
                host?.agentStatus("Compacting the conversation")
                do { try await compact(focus: nil, auto: true) } catch is CancellationError {
                    return finish("Stopped.", ok: false, steps: step)
                } catch {
                    host?.agentError("Auto-compact failed: \(error.localizedDescription)")
                }
            }

            Compactor.slim(&messages)
            messages.append(.user(userText, images: pendingImages))
            onHistory?()
            let raw: String
            do {
                raw = try await brain.reply(messages)
            } catch is CancellationError {
                messages.removeLast()
                onHistory?()
                return finish("Stopped.", ok: false, steps: step)
            } catch {
                keepAfterFailure(goal: goal, step: step)
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                host?.agentError(msg)
                return finish(msg, ok: false, steps: step, silent: true)
            }
            messages.append(.assistant(raw))
            onHistory?()
            pendingImages = []

            let reply: AgentReply
            do {
                reply = try ActionParser.parse(raw)
                parseFailures = 0
            } catch {
                parseFailures += 1
                // Plain-text answer with no JSON at all: treat it as the final reply.
                if !raw.contains("```") && !raw.contains("{") && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return finish(raw.trimmingCharacters(in: .whitespacesAndNewlines), ok: true, steps: step)
                }
                if parseFailures > 2 { return finish("I couldn't produce a usable reply three times in a row and stopped. Try rephrasing.", ok: false, steps: step) }
                userText = "<observation step=\(step)>Your last reply couldn't be used: \(error). If a file's content contains ``` fences, keep the JSON valid by escaping newlines and quotes. \(PromptBuilder.formatReminder)</observation>"
                continue
            }

            if !reply.thought.isEmpty { host?.agentThought(Fmt.plain(reply.thought)) }
            if let m = reply.milestone { host?.agentMilestone(m) }

            // Plan first for big jobs: the owner approves (or edits) before anything runs.
            if !reply.plan.isEmpty && !planApproved && !planShown {
                if let say = reply.say, !say.isEmpty { host?.agentSay(Fmt.plain(say), final: false) }
                let decision = await host?.agentPlan(reply.plan.map(Fmt.plain)) ?? .approve
                if Task.isCancelled { return finish("Stopped.", ok: false, steps: step) }
                switch decision {
                case .cancel:
                    planShown = true
                    return finish("Plan cancelled. Nothing was changed.", ok: true, steps: step)
                case .revise(let note):
                    userText = "<observation step=\(step)>The owner wants the plan changed: \"\(Fmt.line(note, 800))\". Reply with a revised \"plan\" (and no actions).</observation>\n\(PromptBuilder.formatReminder)"
                    continue
                case .approve, .approveAutoEdits:
                    planApproved = true
                    planShown = true
                    if decision == .approveAutoEdits { mode = .acceptEdits } else if mode == .plan { mode = .ask }
                    lastMode = mode
                    if reply.actions.isEmpty || reply.done {
                        userText = "<observation step=\(step)>The owner approved the plan. Start milestone 1 now. Include \"milestone\": n in the reply where milestone n is finished.</observation>\n\(PromptBuilder.formatReminder)"
                        continue
                    }
                }
            }

            if reply.actions.isEmpty {
                if reply.done || reply.say != nil {
                    return finish(reply.say ?? reply.thought, ok: true, steps: step)
                }
                userText = "<observation step=\(step)>No actions were given. If the request is complete, reply with \"done\": true and the answer in \"say\". \(PromptBuilder.formatReminder)</observation>"
                continue
            }
            if let say = reply.say, !say.isEmpty, !reply.done { host?.agentSay(Fmt.plain(say), final: false) }

            // Execute the batch.
            var results: [String] = []
            var images: [(Data, String)] = []
            var anyFailed = false
            for (i, action) in reply.actions.enumerated() {
                if Task.isCancelled { break }
                let r = await execute(action)
                results.append(r.line)
                if let img = r.result.image { images.append(img) }
                if let end = r.result.endTask { return finish(end, ok: false, steps: step) }
                if !r.result.ok || r.result.stopBatch {
                    anyFailed = anyFailed || !r.result.ok
                    if i < reply.actions.count - 1 { results.append("(the remaining \(reply.actions.count - i - 1) action(s) in this batch were skipped)") }
                    break
                }
            }
            if Task.isCancelled { return finish("Stopped.", ok: false, steps: step) }
            if reply.done && !anyFailed { results.append("(you marked this done; check these results, then reply with done:true and the final answer in say)") }

            var obs = "<observation step=\(step)>\nresults of your actions:\n" + results.joined(separator: "\n") + "\n"
            let steering = host?.agentDrainSteering() ?? []
            if !steering.isEmpty {
                obs += "\nMESSAGE FROM THE OWNER (sent while you were working; take it into account now):\n" + steering.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if mode != lastMode {
                obs += "\n(The owner switched the permission mode to \"\(mode.label)\".)\n" + PromptBuilder.modeNote(mode)
                lastMode = mode
            }
            obs += "</observation>\n" + Self.budgetNote(step: step, maxSteps: maxSteps) + Self.timeNote(since: taskStart) + PromptBuilder.formatReminder
            userText = obs
            pendingImages = images
        }
        return finish("I reached the step limit (\(maxSteps)) before finishing. Say \"continue\" to keep going.", ok: false, steps: maxSteps)
    }

    // MARK: One action

    struct Executed { var line: String; var result: ToolResult }

    func execute(_ action: AgentAction) async -> Executed {
        let argsShort = Fmt.line(action.args.compact, 160)
        guard let spec = tools[action.tool] else {
            return Executed(line: "- \(action.tool) → FAILED: unknown action. Use only the listed actions.", result: .fail("unknown"))
        }
        let id = UUID()
        ctx.stepID = id
        let summary = Self.describe(action, root: ctx.root)
        let start = Date()

        if let prepare = spec.prepare {
            host?.agentStepBegan(id, tool: action.tool, summary: summary)
            host?.agentStatus(summary)
            let changes: [FileChange]
            do { changes = try await prepare(action.args, ctx) } catch {
                let msg = (error as? ToolFailure)?.message ?? error.localizedDescription
                host?.agentStepEnded(id, status: .failed, output: msg, diffs: [], duration: Date().timeIntervalSince(start))
                return Executed(line: "- \(action.tool) \(argsShort) → FAILED: \(msg)", result: .fail(msg))
            }
            let diffs = changes.map { $0.diff(root: ctx.root) }
            let decision = Permissions.decide(mode: mode, kind: .edit, paths: changes.map(\.url), root: ctx.root, allowed: allowedCommands)
            if let denied = await gate(decision, tool: action.tool, command: nil, diffs: diffs) {
                host?.agentStepEnded(id, status: .denied, output: denied, diffs: diffs, duration: 0)
                return Executed(line: "- \(action.tool) \(argsShort) → DECLINED: \(denied)", result: .fail(denied))
            }
            do {
                for c in changes {
                    checkpoint.record(c.url, before: c.old)
                    try c.apply()
                }
            } catch {
                host?.agentStepEnded(id, status: .failed, output: error.localizedDescription, diffs: diffs, duration: Date().timeIntervalSince(start))
                return Executed(line: "- \(action.tool) \(argsShort) → FAILED: \(error.localizedDescription)", result: .fail(error.localizedDescription))
            }
            onCheckpoint?(checkpoint)
            let desc = zip(changes, diffs).map { c, d in
                c.new == nil ? "deleted \(d.path)" : c.old == nil ? "created \(d.path) (\(DiffEngine.lines(c.new ?? "").count) lines)" : "edited \(d.path) (+\(d.added) -\(d.removed))"
            }.joined(separator: "; ")
            host?.agentStepEnded(id, status: .ok, output: desc, diffs: diffs, duration: Date().timeIntervalSince(start))
            return Executed(line: "- \(action.tool) \(Self.argsForLog(action)) → ok: \(desc)", result: .ok(desc))
        }

        let kind = spec.effectiveKind(action.args)
        let command = spec.command?(action.args)
        let decision = Permissions.decide(mode: mode, kind: kind, command: command, root: ctx.root, allowed: allowedCommands)
        if let denied = await gate(decision, tool: action.tool, command: command, diffs: []) {
            host?.agentStepBegan(id, tool: action.tool, summary: summary)
            host?.agentStepEnded(id, status: .denied, output: denied, diffs: [], duration: 0)
            return Executed(line: "- \(action.tool) \(argsShort) → DECLINED: \(denied)", result: .fail(denied))
        }
        host?.agentStepBegan(id, tool: action.tool, summary: summary)
        host?.agentStatus(summary)
        var r: ToolResult
        do {
            guard let run = spec.run else { throw ToolFailure("tool has no implementation") }
            r = try await run(action.args, ctx)
        } catch is CancellationError {
            r = .fail("stopped by the owner")
        } catch {
            r = .fail((error as? ToolFailure)?.message ?? "error: \(error.localizedDescription)")
        }
        host?.agentStepEnded(id, status: r.ok ? .ok : .failed, output: r.output, diffs: [], duration: Date().timeIntervalSince(start))
        return Executed(line: "- \(action.tool) \(argsShort) → \(r.ok ? "ok" : "FAILED"): \(Fmt.clip(r.output, max: 16000))", result: r)
    }

    /// Applies the permission decision, asking the owner when needed. Returns the refusal text, or nil to proceed.
    private func gate(_ decision: PermissionDecision, tool: String, command: String?, diffs: [FileDiff]) async -> String? {
        switch decision {
        case .allow: return nil
        case .deny(let why): return why
        case .ask(let reason):
            let key = command.map(Permissions.commandKey)
            host?.agentStatus("Waiting for your approval")
            let answer = await host?.agentPermission(PermissionRequest(tool: tool, reason: reason, command: command, diffs: diffs, commandKey: key)) ?? .deny(nil)
            switch answer {
            case .allow: return nil
            case .allowSession:
                if let key, Permissions.dangerReason(command ?? "") == nil { allowedCommands.insert(key) }
                if command == nil && mode == .ask { mode = .acceptEdits }
                return nil
            case .deny(let note):
                return "the owner declined this action" + (note.map { ". They said: \"\($0)\"" } ?? ". Don't retry it; find another way or finish and explain.")
            }
        }
    }

    // MARK: Compaction

    /// Summarises the conversation and replaces the history with briefing + summary.
    func compact(focus: String?, auto: Bool = false) async throws {
        guard messages.count >= 2 else { return }
        let request = Compactor.summaryRequest(messages, focus: focus)
        let summary = try await brain.reply(request)
        let clean = summary.replacingOccurrences(of: #"```json[\s\S]*?```"#, with: "", options: .regularExpression)
        let base = briefing.isEmpty ? (messages.first?.text ?? "") : briefing
        messages = Compactor.compacted(briefing: base, summary: clean)
        onHistory?()
        onCompacted?(clean)
    }

    // MARK: Helpers

    private func keepAfterFailure(goal: String, step: Int) {
        guard let last = messages.last, last.role == "user" else { return }
        messages.removeLast()
        onHistory?()
        // A failed first turn leaves no history; the briefing is rebuilt next time.
        if messages.isEmpty { return }
        unsent = "(The previous request, \"\(Fmt.line(goal, 200))\", was interrupted at step \(step) because the app couldn't reach you. This is what you hadn't seen yet:)\n" + Fmt.clip(last.text, max: 6000)
    }

    private func finish(_ raw: String, ok: Bool, steps: Int, silent: Bool = false) -> AgentOutcome {
        let text = Fmt.plain(raw)
        if !checkpoint.files.isEmpty { onCheckpoint?(checkpoint) }
        let changed = checkpoint.files.map { Paths.display(URL(fileURLWithPath: $0.path), root: ctx.root) }
        if !silent { host?.agentSay(text, final: true) }
        host?.agentStatus("")
        return AgentOutcome(text: text, ok: ok, steps: steps, changedFiles: changed)
    }

    /// The args as logged in the observation: big contents are summarised so history stays small.
    static func argsForLog(_ a: AgentAction) -> String {
        var o = a.args.object ?? [:]
        for k in ["content", "replace", "find", "text"] { if let s = o[k]?.string, s.count > 120 { o[k] = .string("<\(s.count) chars>") } }
        if let edits = o["edits"]?.array { o["edits"] = .string("<\(edits.count) edits>") }
        return Fmt.line(JSON.object(o).compact, 200)
    }

    /// Human summary of an action for the UI.
    static func describe(_ a: AgentAction, root: URL) -> String {
        let args = a.args
        let path = (args["path"]?.string ?? args["file"]?.string).map { Paths.display(Paths.resolve($0, base: root), root: root) } ?? ""
        switch a.tool {
        case "read_file":
            if let o = args["offset"]?.int { return "Read \(path) from line \(o)" }
            return "Read \(path)"
        case "write_file": return "Write \(path)"
        case "edit_file": return "Edit \(path)"
        case "multi_edit":
            let files = Set((args["edits"]?.array ?? []).compactMap { $0["path"]?.string } + (path.isEmpty ? [] : [path]))
            return "Edit " + (files.count == 1 ? (files.first.map { Paths.display(Paths.resolve($0, base: root), root: root) } ?? path) : "\(files.count) files")
        case "delete_file": return "Delete \(path)"
        case "list_dir": return "List \(path.isEmpty ? "." : path)"
        case "glob": return "Find \(args["pattern"]?.string ?? "")"
        case "grep": return "Search /\(args["pattern"]?.string ?? "")/" + (path.isEmpty ? "" : " in \(path)")
        case "shell": return "$ " + Fmt.line(args["command"]?.string ?? args["cmd"]?.string ?? "", 140)
        case "start_process": return "Start \(args["name"]?.string ?? ShellTools.defaultName(args["command"]?.string ?? "")): \(Fmt.line(args["command"]?.string ?? "", 100))"
        case "read_process": return "Output of \(args["name"]?.string ?? "")"
        case "stop_process": return "Stop \(args["name"]?.string ?? "")"
        case "wait_until": return "Wait until \(args["until"]?.string ?? "") \(Fmt.line(args["value"]?.string ?? "", 60))"
        case "web_search": return "Search the web: \(Fmt.line(args["query"]?.string ?? "", 80))"
        case "fetch_url": return "Fetch \(Fmt.line(args["url"]?.string ?? "", 100))"
        case "todo_write": return "Update todos"
        case "use_skill": return "Use skill \(args["name"]?.string ?? "")"
        case "ask_user": return "Ask: \(Fmt.line(args["question"]?.string ?? "", 100))"
        default: return "\(a.tool) \(Fmt.line(args.compact, 100))"
        }
    }

    static func timeNote(since start: Date) -> String {
        let s = Int(Date().timeIntervalSince(start))
        guard s >= 600 else { return "" }
        return "(Time: this request has been running \(s / 60) min. If something keeps failing, stop and report what you have, what failed and what to try.)\n"
    }

    static func budgetNote(step: Int, maxSteps: Int) -> String {
        let left = maxSteps - step
        if left <= 2 { return "(Budget: only \(left) step(s) left. Finish now: do the last essential action or reply done:true with what is done and what is left.)\n" }
        if left <= 6 { return "(Budget: \(left) steps left. Prioritise and wrap up soon.)\n" }
        return ""
    }
}
