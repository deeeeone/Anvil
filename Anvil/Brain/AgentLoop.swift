import Foundation

struct AgentOutcome {
    var text: String
    var ok: Bool
    var steps: Int
    var changedFiles: [String] = []
    /// The command the app ran to verify the change, when it passed.
    var verifiedBy: String?
    /// Open items the completion check still found when the request stopped (the answer says so).
    var missing: [String] = []
}

/// Observe, think, act loop over the text action protocol (ported from Peep, specialised for coding).
final class Agent {
    let ctx: ToolContext
    var brain: Brain
    private(set) var tools: [String: ToolSpec] = [:]
    private var ordered: [ToolSpec] = []
    /// A read-only helper started by `explore` (no memory writes, no verification, no nested helpers).
    let isSubagent: Bool

    /// The model conversation. Saved with the session, so it can be resumed.
    var messages: [ChatMessage] = []
    /// The fixed part of the first turn (role, rules, catalog, project context), reused when compacting.
    var briefing = ""
    var mode: PermissionMode = .ask { didSet { if mode != oldValue { onModeChange?(mode) } } }
    var allowedCommands = Set<String>()
    var maxSteps = 80
    var autoCompactTokens = 160_000
    /// Run the project's tests (or ask the model to verify) before accepting "done" after edits.
    var autoVerify = true
    /// Have a second call review the final diff (used only when the completion judge is off).
    var selfReview = true
    /// Judge the final answer with a hidden second model call before accepting it (see CompletionJudge).
    var judgeEnabled = true
    /// The judge's model setting: "auto", or a model id.
    var judgeSetting = "auto"
    /// After UI work with a page open in the browser, screenshot it and have a vision model critique it (see DesignCritique).
    var designCheck = true
    /// This request is part of a /goal run: more judge rounds, and dangerous commands are queued, not asked.
    var inGoal = false
    /// The goal's checks (its definition of done) with their latest results.
    var goalCriteria: [GoalCriterion] = []
    /// Goal mode: a dangerous command that needs approval is handed to this instead of asking the owner.
    var queueApprovals: ((PermissionRequest) -> Void)?
    /// Commands the owner approved after they were queued: each runs once.
    var approvedOnce = Set<String>()
    private var verifyReport = ""
    private var criteriaReport = ""
    /// Set when a <check> note went into the conversation; it leaves the history after the next reply.
    private var checkNotesPending = false
    /// Model for a turn after the same action failed twice ("" = never escalate).
    var escalationModel = ""
    /// Model for exploration turns and explore helpers ("" = the session model).
    var exploreModel = ""
    /// When a model fails for good, retry the turn on another ready model (up to two switches per request).
    var autoFallback = true
    /// Told when a request switches models, so the session's model pill follows.
    var onModelFallback: ((String) -> Void)?
    /// Stream replies to the host (live text; early stop for providers that ignore stop sequences).
    var streaming = true
    /// Stop the request once it has cost this much (USD; 0 = no limit).
    var maxCost = 0.0
    private(set) var taskCost = 0.0
    /// Pick reasoning effort per turn (low for wrap-ups and simple requests, full for decisions and after failures).
    var adaptiveEffort = true
    /// Model for requests that look simple (renames, typos); "" = the session model.
    var quickModel = ""
    /// Attach the code a failure points to, and the code around a few grep hits.
    var prefetch = true
    /// While a plan waits for approval, a read-only helper looks ahead at milestone 1.
    var prepareWhilePlanning = true
    /// Ask for a plan when a big job starts editing without one (off for unattended sessions).
    var planNudges = true
    /// After a batch of edits, ask the project's language server for errors the edits introduced.
    var lspChecks = false
    /// Files edited in the current batch, with their text before the batch (nil = new file).
    private var lspTouched: [URL: String?] = [:]
    /// Each file's errors before Anvil first edited it (by message, not line).
    private var lspBaseline: [String: Set<String>] = [:]
    /// The briefing built ahead of time (cache warming); reused if the request starts soon after.
    private var prepared: (text: String, at: Date)?
    // Approvals for the current request and batch.
    private var planEditsApproved = false
    private var batchEditsApproved = false
    private var batchEditsLeft = 0
    /// What this project taught earlier sessions: test/build commands and lessons.
    var memory: ProjectMemory
    /// A turn that never reached the model (network failure), re-sent with the next request.
    private var unsent: String?
    private var checkpoint = Checkpoint(label: "")

    // Per-request state.
    private var currentStep = 0
    private var editedSinceVerify = false
    private var failureCounts: [String: Int] = [:]
    private var escalateNext = false
    private var lastFailure: String?
    /// When the current request started (set in run).
    private var requestStart = Date()
    /// The last finished request: start, end and steps. Answers "how long did that take" on a follow-up.
    var lastRequest: (start: Date, end: Date, steps: Int)?
    /// read_file results recently shown to the model: path|offset|limit → (modification date, step).
    private var readCache: [String: (Date, Int)] = [:]

    /// Tools the model has been told about in this conversation (nil = unknown: read them from the briefing).
    var briefedTools: Set<String>?

    /// Tool names listed in a briefing's catalog.
    static func toolNames(inBriefing b: String) -> Set<String> {
        guard let r = b.range(of: "ACTIONS\n") else { return [] }
        let re = try! NSRegularExpression(pattern: #"(?m)^- ([a-z_][a-z0-9_.]*) "#)
        let tail = String(b[r.upperBound...])
        let ns = NSString(string: tail)
        return Set(re.matches(in: tail, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    /// Catalog lines for tools this conversation hasn't been told about yet (it started before they existed).
    func unannouncedTools() -> [String] {
        let known = briefedTools ?? Self.toolNames(inBriefing: briefing.isEmpty ? (messages.first?.text ?? "") : briefing)
        let fresh = ordered.filter { !known.contains($0.name) }
        briefedTools = known.union(fresh.map(\.name))
        return fresh.map(\.catalogLine)
    }

    /// Supplies tools that can appear while the agent lives (MCP servers that finish connecting later).
    var toolProvider: (() -> [ToolSpec])?
    private var knownToolNames = Set<String>()

    var onModeChange: ((PermissionMode) -> Void)?
    var onCheckpoint: ((Checkpoint) -> Void)?
    /// Called whenever `messages` changes (persist the session).
    var onHistory: (() -> Void)?
    var onCompacted: ((String) -> Void)?
    /// The NotebookLM notebook that ask_memory queries instead of the project's memory (set by /notebook).
    var attachedNotebook: String?
    /// The project the NotebookLM memory belongs to (the project, not a worktree).
    var memoryRoot: URL?
    /// The session's title, used to name what compaction saves to memory.
    var memoryTitle: String?
    /// How many messages are already in memory (nil = none), set by the session.
    var memoryUploadedCount: (() -> Int?)?
    /// ask_memory calls in the current request (at most three), and this session's answers by question.
    private var memoryAsks = 0
    private var memoryAnswers: [String: String] = [:]

    init(ctx: ToolContext, brain: Brain, extraTools: [ToolSpec] = [], subagent: Bool = false) {
        self.ctx = ctx
        self.brain = brain
        self.isSubagent = subagent
        self.memory = subagent ? ProjectMemory() : ProjectMemory.load(ctx.root)
        var specs = FileTools.all() + ShellTools.all() + WorkTools.all() + [Self.repoMapTool] + extraTools
#if os(macOS)
        if !subagent { specs += SimulatorTools.all() }
#endif
        if subagent { specs.removeAll { ["ask_user", "todo_write", "start_process", "stop_process"].contains($0.name) } }
        register(specs)
        if !subagent { register([exploreTool()] + mcpTools() + GitHub.tools()) }
        if ctx.browser != nil && !subagent { register(BrowserTools.all()) }
        registerMemoryTool()
        knownToolNames = Set(tools.keys)
    }

    /// Whether ask_memory is useful now: a notebook is attached, or memory has saved or compacted this session,
    /// or the session is long and the project's notebook already holds earlier sessions (never for helpers).
    var wantsMemoryTool: Bool {
        guard !isSubagent else { return false }
        return MemoryRules.offerTool(attached: attachedNotebook != nil, uploaded: memoryUploadedCount?() != nil,
                                     tokens: Compactor.estimateTokens(messages, model: brain.model),
                                     notebookHasUploads: NotebookMemory.shared.hasUploads(root: memoryRoot ?? ctx.root),
                                     memoryOn: AppSettings.shared.notebookMemory)
    }

    /// Registers ask_memory when it is wanted and removes it when it is not.
    func registerMemoryTool() {
        if wantsMemoryTool { register([askMemorySpec()]) } else { unregister("ask_memory") }
    }

    /// The tool list the agent asks for each step: ask_memory appears mid-session once the session grows long.
    func memoryToolSpecs() -> [ToolSpec] { wantsMemoryTool ? [askMemorySpec()] : [] }

    /// Removes a tool from this agent. It comes back through the tool provider when it is wanted again.
    func unregister(_ name: String) {
        guard tools[name] != nil else { return }
        tools[name] = nil
        ordered.removeAll { $0.name == name }
        knownToolNames.remove(name)
    }

    private func askMemorySpec() -> ToolSpec {
        ToolSpec(name: "ask_memory", kind: .network, signature: #"{"question": str}"#,
                 summary: "ask this project's long-term memory (NotebookLM, holding full transcripts of earlier sessions and any notebook the owner attached) and get a cited answer; use it when the owner refers to past work or a detail may have been lost to compaction",
                 group: .search) { [weak self] args, _ in
            guard let self else { return ToolResult(ok: false, output: "The agent is gone.") }
            return await self.askMemory(args["question"]?.string ?? "")
        }
    }

    /// ask_memory: at most three questions per request. An identical question is answered from this session's cache.
    func askMemory(_ question: String) async -> ToolResult {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ToolResult(ok: false, output: "Give a question: {\"question\": \"...\"}") }
        let key = q.lowercased()
        if let cached = memoryAnswers[key] { return .ok(cached) }
        guard memoryAsks < 3 else {
            return ToolResult(ok: false, output: "ask_memory was already used 3 times for this request. Continue from the conversation and files.")
        }
        memoryAsks += 1
        do {
            let answer = try await NotebookMemory.shared.ask(q, root: memoryRoot ?? ctx.root, notebook: attachedNotebook)
            memoryAnswers[key] = answer
            return .ok(answer)
        } catch {
            return ToolResult(ok: false, output: NotebookMemory.message(error))
        }
    }

    /// Picks up tools that appeared since the last step. Returns catalog lines for the new ones.
    @discardableResult
    func refreshTools() -> [String] {
        guard let provider = toolProvider else { return [] }
        let fresh = provider().filter { !knownToolNames.contains($0.name) }
        guard !fresh.isEmpty else { return [] }
        register(fresh)
        knownToolNames.formUnion(fresh.map(\.name))
        briefedTools?.formUnion(fresh.map(\.name))
        return fresh.map(\.catalogLine)
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
        var info = PromptBuilder.ProjectInfo(root: root, git: await Git.status(root, untrackedAll: false), layout: ProjectContext.layout(root),
                                             memory: ProjectContext.memory(root), skills: [], skillCount: skills.count)
        info.repoMap = await Task.detached { RepoMap.build(root) }.value
        if let t = memory.testCommand { info.testCommand = t; info.testCommandProven = true }
        else { info.testCommand = ProjectMemory.guessTestCommand(root) }
        info.buildCommand = memory.buildCommand
        info.lessons = memory.lessons
        if !isSubagent, let b = ProjectBrief.load(root) { info.brief = b.text }
        return info
    }

    /// The first turn's fixed text: rules, catalog, project context. Goal-independent, so it can be built (and cached
    /// by the provider) while the owner is still typing.
    func buildBriefing() async -> String {
        if let p = prepared, Date().timeIntervalSince(p.at) < 300 { return p.text }
        let info = await projectInfo()
        let text = PromptBuilder.fixed(catalog: catalog) + PromptBuilder.projectContext(info)
        prepared = (text, Date())
        return text
    }

    /// Warm the provider's prompt cache with what the next request will start with.
    func warmCache() async {
        if messages.isEmpty {
            refreshTools()
            let b = await buildBriefing()
            await brain.warm([.user(b)])
        } else if messages.last?.role == "assistant" {
            await brain.warm(messages + [.user("(warming the cache; no reply needed)")])
        }
    }

    /// Writes (or refreshes) the project brief with a fast, low-effort call. Skips the call when the code's shape is unchanged.
    @discardableResult
    static func refreshBrief(root: URL, brain: Brain) async -> ProjectBrief? {
        let map = await Task.detached { RepoMap.build(root) }.value
        let layout = ProjectContext.layout(root)
        guard !map.isEmpty || layout != "(empty folder)" else { return nil }
        let fp = ProjectBrief.fingerprint(repoMap: map + layout)
        if let old = ProjectBrief.load(root), old.fingerprint == fp { return old }
        guard let text = try? await brain.oneShot(ProjectBrief.prompt(root: root, repoMap: map, layout: layout), effort: "low") else { return nil }
        let b = ProjectBrief(text: Fmt.plain(text.trimmingCharacters(in: .whitespacesAndNewlines)), fingerprint: fp, created: Date())
        b.save(root)
        return b
    }

    /// The model to retry a failed turn on, or nil when none is left. Favorites come first, then the other ready models.
    /// A bad key, quota or account problem also rules out every model from the failed model's provider.
    nonisolated static func fallbackModel(after failed: String, error: BrainError?, favorites: [String], available: [String],
                                          sameProvider: (String, String) -> Bool, ready: (String) -> Bool, skipProvider: Bool = false) -> String? {
        let authProblem = skipProvider || error.map { e in
            ["no_key", "unauthorized", "revoked"].contains(e.code) || e.status == 401 || e.status == 403 || e.message.lowercased().contains("revoked")
        } ?? false
        var seen = Set<String>()
        for m in favorites.filter({ available.contains($0) }) + available {
            if m == failed || seen.contains(m) { continue }
            seen.insert(m)
            guard ready(m) else { continue }
            if authProblem && sameProvider(m, failed) { continue }
            return m
        }
        return nil
    }

    /// Re-anchoring stays available while the model keeps making progress: at most three slips in a row (the second
    /// one also hands the turn to another provider's model) and eight in one request.
    nonisolated static func mayReanchor(total: Int, sinceAction: Int) -> Bool { total < 8 && sinceAction < 3 }

    static func reanchorNote(acted: Bool, goal: String) -> String {
        let proof = acted ? " You already ran actions successfully in this request: their results are in the observations above. Nothing about that has changed." : ""
        return "\(reanchorText) That includes file, shell and browser tools (see the tool catalog in the first message). Ignore any tools the chat service itself shows you (such as retriever:expand_tools): they are not yours here. You act only through the json block.\(proof) Continue with the request: \"\(Fmt.line(goal, 300))\". Reply with the next actions. \(PromptBuilder.formatReminder)"
    }

    static let reanchorText = "You do have access. This app executes the actions you list in the json block, on the owner's project, with their permission, and sends you the results. You never need the owner to paste files or run commands."

    // MARK: Run

    func run(goal: String, images: [(Data, String)] = [], attachmentsNote: String = "") async -> AgentOutcome {
        brain.effortCap = nil
        memoryAsks = 0
#if canImport(Darwin)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Anvil is working on a task")
        defer { ProcessInfo.processInfo.endActivity(activity) }
#endif
        let taskStart = Date()
        requestStart = taskStart
        checkpoint = Checkpoint(label: Fmt.line(goal, 80))
        editedSinceVerify = false
        failureCounts = [:]
        escalateNext = false
        lastFailure = nil
        taskCost = 0
        let priorUsage = brain.onUsage
        brain.onUsage = { [weak self] u, m, c in self?.taskCost += c ?? 0; priorUsage?(u, m, c) }
        defer { brain.onUsage = priorUsage }
        if streaming && !isSubagent { brain.onStream = host.map { h in { [weak h] text in h?.agentStream(text) } } }
        defer { brain.onStream = nil; host?.agentStream("") }

        refreshTools()
        let jail = AppSettings.shared.jailbreak ? Jailbreak.prompt(for: Providers.provider(for: brain.model), query: goal) : ""
        let size: RequestSize = isSubagent ? .question : RequestSize.classify(goal)
        planEditsApproved = false
        var intro: String
        let skillNote = SkillLibrary.skillNote(for: goal, project: ctx.root, firstTurn: messages.isEmpty && !isSubagent)
        if messages.isEmpty {
            briefing = await buildBriefing()
            prepared = nil
            briefedTools = Set(tools.keys)
            intro = briefing + skillNote + jail + PromptBuilder.request(goal, attachments: attachmentsNote)
        } else {
            // A resumed conversation may predate tools Anvil has gained since: list them before the request.
            let fresh = unannouncedTools()
            let note = fresh.isEmpty ? "" : "NEW TOOLS AVAILABLE NOW (added since this conversation started; same reply format):\n" + fresh.joined(separator: "\n") + "\n\n"
            let previous = lastRequest.map { Self.previousRequestLine(start: $0.start, end: $0.end, steps: $0.steps) + "\n\n" } ?? ""
            intro = previous + note + skillNote + jail + PromptBuilder.followUp(goal, attachments: attachmentsNote)
        }
        // After the fixed briefing (prompt caching), next to the request.
        if designCheck && !isSubagent && ctx.browser != nil && SkillLibrary.isUIRequest(goal) { intro += "\n\n" + DesignCritique.brief }
        var userText = (unsent.map { $0 + "\n\n" } ?? "") + intro + (isSubagent ? "" : PromptBuilder.modeNote(mode)) + PromptBuilder.formatReminder
        unsent = nil
        var pendingImages = images
        var parseFailures = 0
        /// Replies this request that were cut off (see Brain.isCutOff); their actions never run.
        var cutOffs = 0
        var reanchors = 0
        /// Re-anchors since the model last ran an action batch (it slipped again without doing anything in between).
        var reanchorsSinceAction = 0
        var actedThisRequest = false
        var editedThisRequest = false
        var sentBackForNoAction = false
        var askedForPlan = false
        var askedForSummary = false
        var askedForContent = false
        var lastBatchExploratory = false
        var lastBatchFailed = false
        var verifyRuns = 0
        var askedToVerify = false
        var reviewed = false
        /// The completion check's rounds for this request (more in goal mode).
        var judge = CompletionJudge.Tracker(cap: inGoal ? 6 : 3)
        /// The design check's rounds, the files as they were in its best-scoring round, and whether it has finished.
        var design = DesignCritique.Tracker()
        var designBest: [(path: String, text: String?)] = []
        var designSettled = false
        var verifiedBy: String?
        var planApproved = false
        var planShown = false
        /// The approved plan's milestones and how many are finished, so a progress note mid-plan isn't taken for the end.
        var planSteps: [String] = []
        var milestonesDone = 0
        var progressNudges = 0
        var fallbackSwitches = 0
        var forcedModel: String?
        /// A model that says "I have no tools" twice in a row without acting in between is stuck in its chat app's
        /// persona (web models slip into it). Hand the next turn to a model from another provider.
        func switchAfterRepeatedClaims(sinceAction: Int) {
            guard sinceAction >= 2, autoFallback, fallbackSwitches < 2, !isSubagent else { return }
            let current = forcedModel ?? brain.model
            guard let next = Self.fallbackModel(after: current, error: nil, favorites: AppSettings.shared.favoriteModels,
                                                available: ModelCatalog.shared.choices.map(\.id),
                                                sameProvider: { Providers.label(for: $0) == Providers.label(for: $1) },
                                                ready: { AppSettings.shared.ready(model: $0) }, skipProvider: true) else { return }
            fallbackSwitches += 1
            forcedModel = next
            brain.model = next
            onModelFallback?(next)
            host?.agentError("\(current) kept saying it can't use tools. Switched to \(next) for the rest of this request.")
        }
        var lastMode = mode
        let maxSteps = max(3, self.maxSteps)

        for step in 1...maxSteps {
            currentStep = step
            if Task.isCancelled { return finish("Stopped.", ok: false, steps: step) }
            host?.agentStatus(step == 1 ? "Thinking" : "Thinking (step \(step))")

            // Compact before the context gets too big (keeps the pending turn).
            if Compactor.shouldCompact(messages, limit: autoCompactTokens, model: brain.model) {
                host?.agentStatus("Compacting the conversation")
                do { try await compact(focus: nil, auto: true) } catch is CancellationError {
                    return finish("Stopped.", ok: false, steps: step)
                } catch {
                    host?.agentError("Auto-compact failed: \(error.localizedDescription)")
                }
            }

            // Which model thinks this turn, and how hard: escalation after repeated failures, a quick model for simple
            // requests, a fast model while only exploring; effort follows what the turn is likely to do.
            var turnModel: String?
            var turnEffort: String? = nil
            var cap: Int? = nil
            let escalating = escalateNext && !escalationModel.isEmpty && escalationModel != brain.model
            if let forcedModel {
                // This request switched models after a failure: keep using the replacement.
                turnModel = forcedModel
            } else if escalating {
                turnModel = escalationModel
                host?.agentStatus("Thinking harder (\(escalationModel))")
            } else if size == .simple && !quickModel.isEmpty && !lastBatchFailed {
                turnModel = quickModel
            } else if !exploreModel.isEmpty && lastBatchExploratory && !editedThisRequest && step > 1 {
                turnModel = exploreModel
            }
            if adaptiveEffort && !escalating {
                let st = AdaptiveEffort.State(step: step, size: size, editedThisRequest: editedThisRequest, lastBatchExploratory: lastBatchExploratory,
                                              lastBatchFailed: lastBatchFailed, verifiedSinceEdit: editedThisRequest && !editedSinceVerify, parseFailures: parseFailures)
                turnEffort = AdaptiveEffort.effort(st, full: brain.effort)
                // Wrap-up turns (verified edits) only need the final answer: cap the reply.
                if editedThisRequest && !editedSinceVerify && !lastBatchFailed { cap = 2500 }
                if turnEffort != brain.effort { host?.agentStatus(step == 1 ? "Thinking (\(turnEffort!) effort)" : "Thinking (step \(step), \(turnEffort!) effort)") }
            }
            escalateNext = false

            Compactor.slim(&messages)
            messages.append(.user(userText, images: pendingImages))
            onHistory?()
            var raw: String
            do {
                raw = try await brain.reply(messages, model: turnModel, effort: turnEffort, maxTokens: cap)
                // A capped reply that got cut off: redo the turn without the cap.
                if cap != nil && brain.lastFinishReason == "length" {
                    raw = try await brain.reply(messages, model: turnModel, effort: turnEffort, maxTokens: nil)
                }
            } catch is CancellationError {
                messages.removeLast()
                onHistory?()
                return finish("Stopped.", ok: false, steps: step)
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // The model failed for good: retry this same turn on another ready model (two switches at most).
                let failed = turnModel ?? brain.model
                if autoFallback && fallbackSwitches < 2,
                   let next = Self.fallbackModel(after: failed, error: error as? BrainError, favorites: AppSettings.shared.favoriteModels,
                                                 available: ModelCatalog.shared.choices.map(\.id),
                                                 sameProvider: { Providers.label(for: $0) == Providers.label(for: $1) },
                                                 ready: { AppSettings.shared.ready(model: $0) }) {
                    fallbackSwitches += 1
                    forcedModel = next
                    brain.model = next
                    onModelFallback?(next)
                    host?.agentError("\(failed) failed: \(Fmt.line(msg, 120)). Switched to \(next) and retrying.")
                    if messages.last?.role == "user" { messages.removeLast(); onHistory?() }
                    continue
                }
                keepAfterFailure(goal: goal, step: step)
                host?.agentError(msg)
                return finish(msg, ok: false, steps: step, silent: true)
            }
            host?.agentStream("")
            messages.append(.assistant(raw))
            clearCheckNotes()
            if maxCost > 0 && taskCost >= maxCost && !isSubagent {
                onHistory?()
                return finish("Stopped at this request's cost limit (\(Fmt.dollars(maxCost)); spent \(Fmt.dollars(taskCost))). Say \"continue\" to keep going, or raise the limit with /limit.", ok: false, steps: step)
            }
            onHistory?()
            pendingImages = []

            let reply: AgentReply
            do {
                // A cut-off reply may hold a half-written file the lenient parser would repair and run: nothing from it runs.
                if Brain.isCutOff(raw, finishReason: brain.lastFinishReason) {
                    // Never fall through to the lenient parser: it would "repair" the reply and could write a truncated file.
                    guard cutOffs < 3 else {
                        host?.agentError("The model's replies were cut off three times in a row.")
                        return finish("The model's replies kept getting cut off before they finished, so nothing from them ran. Try a shorter request, /compact, or another model.", ok: false, steps: step)
                    }
                    cutOffs += 1
                    userText = "<observation step=\(step)>Your last reply was cut off before it finished (the json block never closed). Nothing from it ran. Send it again, shorter: split big file writes into several smaller edits.</observation>"
                    continue
                }
                reply = try ActionParser.parse(raw)
                parseFailures = 0
            } catch {
                parseFailures += 1
                // Chat-tuned models sometimes say they "can't access files". They can: re-anchor them (twice at most).
                if Self.looksLikeCantAct(raw), Self.mayReanchor(total: reanchors, sinceAction: reanchorsSinceAction) {
                    reanchors += 1
                    reanchorsSinceAction += 1
                    switchAfterRepeatedClaims(sinceAction: reanchorsSinceAction)
                    userText = "<observation step=\(step)>\(Self.reanchorNote(acted: actedThisRequest, goal: goal))</observation>"
                    continue
                }
                // Plain-text answer with no JSON at all: treat it as the final reply, unless it only announces what it will do.
                // A provider's canned failure text ("I seem to be encountering an error…") is never the answer.
                if GeminiWebClient.isServiceError(raw) {
                    host?.agentError("The model answered with its service's canned error text instead of a reply. Asking it again.")
                }
                if !raw.contains("```") && !raw.contains("{") && !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !Self.announcesIntent(raw)
                    && !GeminiWebClient.isServiceError(raw) {
                    // Goes through the same done gate as a json answer (verify, design check, judge), not straight out.
                    reply = AgentReply(thought: "", say: raw.trimmingCharacters(in: .whitespacesAndNewlines), actions: [], done: true)
                    parseFailures = 0
                } else {
                    if parseFailures > 2 { return finish("I couldn't produce a usable reply three times in a row and stopped. Try rephrasing.", ok: false, steps: step) }
                    if parseFailures == 2 && !escalationModel.isEmpty { escalateNext = true }
                    userText = "<observation step=\(step)>Your last reply couldn't be used: \(error). If a file's content contains ``` fences, keep the JSON valid by escaping newlines and quotes. \(PromptBuilder.formatReminder)</observation>"
                    continue
                }
            }

            if !reply.thought.isEmpty { host?.agentThought(Fmt.plain(reply.thought)) }
            if let m = reply.milestone { host?.agentMilestone(m); milestonesDone = max(milestonesDone, m) }

            // Plan first for big jobs: the owner approves (or edits) before anything runs.
            if !reply.plan.isEmpty && !planApproved && !planShown && !isSubagent {
                if let say = reply.say, !say.isEmpty { host?.agentSay(Fmt.plain(say), final: false) }
                // While the owner reads the plan, a read-only helper looks ahead at milestone 1.
                var prep: Task<String?, Never>?
                var prepID: UUID?
                if prepareWhilePlanning && !isSubagent {
                    let id = UUID()
                    prepID = id
                    host?.agentStepBegan(id, tool: "explore", summary: "Preparing milestone 1 while you review the plan")
                    ctx.stepID = id
                    let plan = reply.plan
                    prep = Task { [weak self] in
                        guard let self else { return nil }
                        let r = await self.runExplorer("Prepare for this plan's first milestone: \"\(plan[0])\" (the whole plan: \(plan.joined(separator: "; "))). For the request \"\(Fmt.line(goal, 300))\", find the exact files, functions and line numbers that milestone 1 will change, and note anything surprising.")
                        return r.ok ? r.output : nil
                    }
                }
                let decision = await host?.agentPlan(reply.plan.map(Fmt.plain)) ?? .approve
                if Task.isCancelled { prep?.cancel(); return finish("Stopped.", ok: false, steps: step) }
                var lookAhead = ""
                if let prep {
                    if case .approve = decision {} else if case .approveAutoEdits = decision {} else { prep.cancel() }
                    // Give it a few more seconds if the owner approved fast; otherwise go without it.
                    let report = await withTaskGroup(of: String?.self) { g -> String? in
                        g.addTask { await prep.value }
                        g.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
                        let first = await g.next() ?? nil
                        g.cancelAll()
                        return first
                    }
                    if report == nil { prep.cancel() }
                    if let id = prepID { host?.agentStepEnded(id, status: report == nil ? .denied : .ok, output: report ?? "Skipped", diffs: [], duration: 0) }
                    if let report { lookAhead = "\nWhile the owner reviewed the plan, a read-only helper looked ahead at milestone 1:\n\(Fmt.clip(report, max: 3000))\n" }
                }
                switch decision {
                case .cancel:
                    planShown = true
                    return finish("Plan cancelled. Nothing was changed.", ok: true, steps: step)
                case .revise(let note):
                    userText = "<observation step=\(step)>The owner wants the plan changed: \"\(Fmt.line(note, 800))\". Reply with a revised \"plan\" (and no actions).</observation>\n\(PromptBuilder.formatReminder)"
                    continue
                case .approve, .approveAutoEdits:
                    planApproved = true
                    planSteps = reply.plan
                    planShown = true
                    // Approving a plan approves the edits that carry it out (commands still follow the mode).
                    planEditsApproved = true
                    if decision == .approveAutoEdits { mode = .acceptEdits } else if mode == .plan { mode = .ask }
                    lastMode = mode
                    if reply.actions.isEmpty || reply.done {
                        userText = "<observation step=\(step)>The owner approved the plan. Start milestone 1 now. Include \"milestone\": n in the reply where milestone n is finished.\(lookAhead)</observation>\n\(PromptBuilder.formatReminder)"
                        continue
                    }
                }
            }

            if reply.actions.isEmpty {
                // A "final answer" that claims it has no tools: re-anchor instead, before or after it has acted.
                // Web-chat models (whose own apps have no tools) slip into this even after successful steps.
                if !editedThisRequest && Self.mayReanchor(total: reanchors, sinceAction: reanchorsSinceAction)
                    && Self.looksLikeCantAct((reply.say ?? "") + " " + reply.thought) {
                    reanchors += 1
                    reanchorsSinceAction += 1
                    switchAfterRepeatedClaims(sinceAction: reanchorsSinceAction)
                    userText = "<observation step=\(step)>\(Self.reanchorNote(acted: actedThisRequest, goal: goal))</observation>"
                    continue
                }
                // A request for work (build, fix, add…) "finished" without a single action: the model described the
                // work instead of doing it (often a plan or code dump wrapped in "I'm in a sandbox"). Send it back once.
                let finalText = (reply.say ?? reply.thought).trimmingCharacters(in: .whitespacesAndNewlines)
                if !actedThisRequest && !sentBackForNoAction && reply.explicitDone && size != .question
                    && Self.asksForWork(goal) && !finalText.hasSuffix("?") {
                    sentBackForNoAction = true
                    userText = "<observation step=\(step)>You answered without taking any action, but this request asks you to change the project. \(Self.reanchorText) Don't describe or paste the work: do it with your tools (read the relevant files, then write and edit them, then run it). Continue with the request: \"\(Fmt.line(goal, 300))\". \(PromptBuilder.formatReminder)</observation>"
                    continue
                }
                // "I'll implement that and check it." with no actions and no explicit done: it meant to act.
                if !reply.explicitDone && Self.announcesIntent(reply.say ?? reply.thought) && parseFailures == 0 && reanchors < 3 {
                    reanchors += 1
                    userText = "<observation step=\(step)>Your reply described what you'll do but had no actions, so nothing happened. Put the actions in the json block now (or reply with \"done\": true if the request is already complete). \(PromptBuilder.formatReminder)</observation>"
                    continue
                }
                // A progress note is not the end: "Milestone 1 done…" with done:false (or with milestones still open) means
                // the model meant to keep going. Show it and ask for the next step instead of finishing the request.
                if let next = Self.nextStep(done: reply.done, explicitDone: reply.explicitDone, planSteps: planApproved ? planSteps : [],
                                            milestonesDone: milestonesDone, text: reply.say ?? reply.thought),
                   !isSubagent, progressNudges < (planApproved && milestonesDone < planSteps.count ? planSteps.count + 1 : 1) {
                    progressNudges += 1
                    if let say = reply.say, !say.isEmpty { host?.agentSay(Fmt.plain(say), final: false) }
                    userText = "<observation step=\(step)>Noted. That was a progress update, so the request goes on. Continue now with \(next). Reply with the actions for it; when every part of the request is done, reply with done:true and the final answer.</observation>\n\(PromptBuilder.formatReminder)"
                    continue
                }
                if reply.done || reply.say != nil {
                    // "Here are some ideas for X." and nothing else: the answer announces its content without giving it.
                    if !isSubagent && !askedForContent && Self.announcesContent(reply.say ?? reply.thought) {
                        askedForContent = true
                        userText = "<observation step=\(step)>Your final answer only introduces the content (\"\(Fmt.line(reply.say ?? reply.thought, 120))\") without giving it. Reply again with done:true and the complete answer in say, including the actual list, steps or text you announced.</observation>\n\(PromptBuilder.formatReminder)"
                        continue
                    }
                    // Done gate: changed files must be verified, then reviewed, before the answer is accepted.
                    if !isSubagent && editedThisRequest {
                        if autoVerify && editedSinceVerify && verifyRuns < 2 {
                            verifyRuns += 1
                            // A check that covers the files this request changed (not just any remembered test command).
                            let changed = checkpoint.files.map(\.path)
                            if let cmd = ProjectMemory.verifyCommand(changed: changed, root: ctx.root, remembered: memory.testCommand) {
                                host?.agentStatus("Verifying")
                                let r = await execute(AgentAction(tool: "shell", args: .object(["command": .string(cmd)])), label: "Verify: \(cmd)")
                                // A check that exits 0 but shows a failure, or hides one behind ||, doesn't pass.
                                let passed = r.result.ok && !OutputCheck.hasOrChain(cmd)
                                verifyReport = "Ran `\(cmd)`: \(passed ? "passed" : "FAILED")\n" + Fmt.clip(r.result.output, max: 2000)
                                if passed {
                                    editedSinceVerify = false
                                    verifiedBy = cmd
                                    remember(command: cmd)
                                } else if !r.line.contains("DECLINED") {
                                    userText = "<observation step=\(step)>Before accepting done, the app ran the project's tests and they FAILED:\n\(r.line)\nFix the problem and verify (or explain why the failure has nothing to do with your change), then finish.</observation>\n\(PromptBuilder.formatReminder)"
                                    continue
                                }
                            } else if !askedToVerify {
                                askedToVerify = true
                                userText = "<observation step=\(step)>You changed files after your last successful build or test run. Verify the change works (run the tests, build, or execute the code) before finishing, or reply done:true again with one line on why it can't be verified.</observation>\n\(PromptBuilder.formatReminder)"
                                continue
                            }
                        }
                        // Without the completion judge, a second call reviews the diff (the judge takes its place).
                        if selfReview && !reviewed && !judgeEnabled {
                            reviewed = true
                            if let issues = await review(goal) {
                                userText = "<observation step=\(step)>A reviewer read your diff for this request and flagged:\n\(issues)\nFix the real problems and verify again, or reply done:true if none of these are real problems (say why in one line).</observation>\n\(PromptBuilder.formatReminder)"
                                continue
                            }
                        }
                    }
                    // Design check (hidden from the chat): UI work with a page open gets screenshotted at desktop and phone
                    // size and critiqued by a vision model. Blockers and majors go back as a <design-check> note, for up to
                    // 3 rounds; a round that scores worse than the best one restores the best version's files and stops.
                    if !isSubagent && editedThisRequest && designCheck && !designSettled && ctx.browser != nil
                        && DesignCritique.isUIWork(uiRequest: SkillLibrary.isUIRequest(goal), changedPaths: checkpoint.files.map(\.path))
                        && !(step >= maxSteps - 2 || (maxCost > 0 && taskCost >= maxCost)) && !Task.isCancelled {
                        if let c = await designCritique(goal: goal) {
                            let fixes = DesignCritique.actionable(c.fixes)
                            let next = design.record(score: c.score, actionable: fixes.count)
                            if design.bestRound == design.rounds {
                                designBest = checkpoint.files.map { ($0.path, try? String(contentsOfFile: $0.path, encoding: .utf8)) }
                            }
                            switch next {
                            case .fix:
                                userText = "<observation step=\(step)>Before accepting done, the app reviewed screenshots of the page.</observation>\n\(DesignCritique.note(score: c.score, fixes: fixes))\n\(PromptBuilder.formatReminder)"
                                checkNotesPending = true
                                continue
                            case .revert:
                                restoreDesignBest(designBest)
                                designSettled = true
                            case .accept:
                                designSettled = true
                            }
                        } else {
                            designSettled = true   // no page, no vision model, or no usable critique: skip quietly
                        }
                    }
                    // After real work, a one-liner ("Fixed the issues.") leaves the owner to ask what exists, where it is and
                    // how to use it. Ask for a proper summary once.
                    if !isSubagent && editedThisRequest && !askedForSummary && size != .simple
                        && goal.split(whereSeparator: \.isWhitespace).count >= 6
                        && Self.isThinAnswer(reply.say ?? reply.thought) {
                        askedForSummary = true
                        userText = "<observation step=\(step)>Your final answer doesn't say enough for the work you did. Reply again with done:true and a short answer: what exists now and where, how to open or run it (the exact command or URL), how you checked it, and anything not done. 4 to 8 short lines, no file inventories.</observation>\n\(PromptBuilder.formatReminder)"
                        continue
                    }
                    // Completion check (hidden from the chat): the goal's command and file checks, then the judge. Open items go
                    // back to the model in a <check> note. A repeated miss, the round cap or the budget ends it, and the
                    // answer says what stayed unresolved.
                    var open: [String] = []
                    if !isSubagent {
                        var misses = await criteriaMisses()
                        if judgeEnabled && (actedThisRequest || size != .question),
                           let judged = await judgeAnswer(goal: goal, answer: reply.say ?? reply.thought) {
                            misses += judged.filter { !misses.contains($0) }
                        }
                        if !misses.isEmpty {
                            let fix = judge.record(misses)
                            let budgetOut = step >= maxSteps - 1 || (maxCost > 0 && taskCost >= maxCost)
                            if !fix.isEmpty && !judge.exhausted && !budgetOut && !Task.isCancelled {
                                userText = "<observation step=\(step)>The request isn't finished yet.</observation>\n\(CompletionJudge.checkNote(fix))\n\(PromptBuilder.formatReminder)"
                                checkNotesPending = true
                                continue
                            }
                            open = judge.unresolved + fix.filter { !judge.unresolved.contains($0) }
                        }
                    }
                    var answer = reply.say ?? reply.thought
                    if let v = verifiedBy, !answer.contains(v) { answer += "\n\nVerified: `\(v)` passed." }
                    if !open.isEmpty { answer += "\n\n" + CompletionJudge.unresolvedLine(open) }
                    var outcome = finish(answer, ok: true, steps: step, verifiedBy: verifiedBy)
                    outcome.missing = open
                    return outcome
                }
                userText = "<observation step=\(step)>No actions were given. If the request is complete, reply with \"done\": true and the answer in \"say\". \(PromptBuilder.formatReminder)</observation>"
                continue
            }
            // A big job started without a plan (a long request, or a first reply changing several files): ask for
            // milestones once, so the owner sees the shape of the work and progress can be tracked.
            if planNudges && !isSubagent && !planShown && !planApproved && !askedForPlan && reply.plan.isEmpty && !editedThisRequest
                && (size == .feature || size == .hard) && Self.asksForWork(goal) && mode != .plan
                && reply.actions.contains(where: { tools[$0.tool]?.prepare != nil })   // reading first is fine; plan before editing
                && (goal.split(whereSeparator: \.isWhitespace).count >= 50
                    || reply.actions.filter({ tools[$0.tool]?.prepare != nil }).count >= 3) {
                askedForPlan = true
                userText = "<observation step=\(step)>Your edits in that reply did not run. This is a big job: reply first with a \"plan\" of 3-7 concrete milestones (and no actions), then work through it, marking each finished milestone with \"milestone\": n. \(PromptBuilder.formatReminder)</observation>"
                continue
            }
            if let say = reply.say, !say.isEmpty, !reply.done { host?.agentSay(Fmt.plain(say), final: false) }

            // Execute the batch: runs of read-only actions go in parallel, everything else in order.
            var results: [String] = []
            var images: [(Data, String)] = []
            var anyFailed = false
            actedThisRequest = true
            reanchorsSinceAction = 0
            lastBatchExploratory = reply.actions.allSatisfy { isParallelSafe($0) }
            let actions = reply.actions
            batchEditsApproved = false
            batchEditsLeft = actions.filter { tools[$0.tool]?.prepare != nil }.count
            var i = 0
            batch: while i < actions.count {
                if Task.isCancelled { break }
                var j = i
                while j < actions.count, isParallelSafe(actions[j]) { j += 1 }
                if j - i < 2 { j = i + 1 }
                let group = Array(actions[i..<j])
                let executed = group.count > 1 ? await executeParallel(group) : [await execute(group[0])]
                var stop = false
                for r in executed {
                    results.append(r.line)
                    if let img = r.result.image { images.append(img) }
                    if let end = r.result.endTask { return finish(end, ok: false, steps: step) }
                    if r.edited { editedThisRequest = true; editedSinceVerify = true }
                    // Running a check only counts when it covers what was changed (Python tests don't check a .tsx edit).
                    if r.verified, ProjectMemory.covers(r.command ?? "", changed: checkpoint.files.map(\.path)) { editedSinceVerify = false }
                    if !r.result.ok {
                        let key = "\(r.action.tool) \(r.action.args["path"]?.string ?? r.command ?? "")"
                        // Only failures of the model's own work count toward a model switch (not the environment).
                        if Self.countsTowardEscalation(tool: r.action.tool, command: r.command, output: r.result.output, declined: r.line.contains("→ DECLINED")) {
                            failureCounts[key, default: 0] += 1
                            if failureCounts[key]! >= (size == .hard ? 2 : 3) && !escalationModel.isEmpty { escalateNext = true }
                        }
                        lastFailure = "\(r.action.tool) \(Fmt.line(Self.argsForLog(r.action), 100)) failed: \(Fmt.line(r.result.output, 140))"
                    }
                    if !r.result.ok || r.result.stopBatch { anyFailed = anyFailed || !r.result.ok; stop = true }
                }
                if stop {
                    if j < actions.count { results.append("(the remaining \(actions.count - j) action(s) in this batch were skipped)") }
                    break batch
                }
                i = j
            }
            if Task.isCancelled { return finish("Stopped.", ok: false, steps: step) }
            if !lspTouched.isEmpty {
                let notes = await typeCheck()
                if !notes.isEmpty {
                    results.append("TYPE CHECK FAILED (the project's language server reports errors these edits introduced; fix them next):\n" + notes.joined(separator: "\n"))
                    anyFailed = true
                }
            }
            lastBatchFailed = anyFailed
            if reply.done && !anyFailed { results.append("(you marked this done; check these results, then reply with done:true and the final answer in say)") }

            var obs = "<observation step=\(step)>\nresults of your actions:\n" + results.joined(separator: "\n") + "\n"
            if reply.ignoredBlocks > 0 {
                obs += "\n(Your reply contained \(reply.ignoredBlocks + 1) json blocks; only the first ran. Write exactly one block per reply, then stop: the app sends the real results. Never write an observation yourself.)\n"
            }
            if escalateNext && !escalationModel.isEmpty && escalationModel != brain.model {
                obs += "\n(The same action failed twice. A different model takes the next step: re-read the relevant code and try a different approach.)\n"
            }
            let steering = host?.agentDrainSteering() ?? []
            if !steering.isEmpty {
                obs += "\nMESSAGES SENT WHILE YOU WERE WORKING (from the owner unless marked [Message from ...]; take them into account now):\n" + steering.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            if mode != lastMode {
                obs += "\n(The owner switched the permission mode to \"\(mode.label)\".)\n" + PromptBuilder.modeNote(mode)
                lastMode = mode
            }
            let newTools = refreshTools()
            if !newTools.isEmpty {
                obs += "\nNEW TOOLS AVAILABLE NOW (an MCP server finished connecting):\n" + newTools.joined(separator: "\n") + "\n"
            }
            obs += "</observation>\n" + Self.budgetNote(step: step, maxSteps: maxSteps) + Self.timeNote(since: taskStart) + PromptBuilder.formatReminder
            userText = obs
            pendingImages = images
        }
        return finish("I reached the step limit (\(maxSteps)) before finishing. Say \"continue\" to keep going.", ok: false, steps: maxSteps)
    }

    /// Read-only actions that can run at the same time as their neighbours.
    func isParallelSafe(_ a: AgentAction) -> Bool {
        guard let spec = tools[a.tool], spec.prepare == nil else { return false }
        if ["wait", "wait_until", "ask_user", "todo_write"].contains(a.tool) { return false }
        let k = spec.effectiveKind(a.args)
        return k == .read || k == .network
    }

    func executeParallel(_ group: [AgentAction]) async -> [Executed] {
        await withTaskGroup(of: (Int, Executed).self) { g in
            for (k, a) in group.enumerated() {
                g.addTask { @MainActor in (k, await self.execute(a)) }
            }
            var out: [(Int, Executed)] = []
            for await r in g { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Type-checks the files the last batch edited. Returns one line per new error.
    func typeCheck() async -> [String] {
        let touched = lspTouched
        lspTouched = [:]
        var out: [String] = []
        host?.agentStatus("Type-checking")
        for (url, old) in touched.sorted(by: { $0.key.path < $1.key.path }).prefix(8) {
            guard let server = LSP.server(for: url, root: ctx.root),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = ctx.rel(url)
            if lspBaseline[url.path] == nil {
                if let old {
                    guard let before = await LSP.errors(url, text: old, root: ctx.root, server: server) else { continue }
                    lspBaseline[url.path] = Set(before.map(\.key))
                } else {
                    lspBaseline[url.path] = []
                }
            }
            guard let after = await LSP.errors(url, text: text, root: ctx.root, server: server) else { continue }
            out += LSP.introduced(after: after, baseline: lspBaseline[url.path] ?? [], path: path)
        }
        return out
    }

    /// A passing test or build command is remembered for this project (and re-run automatically before "done").
    private func remember(command cmd: String) {
        guard !isSubagent else { return }
        if ProjectMemory.isTestCommand(cmd), memory.testCommand != cmd { memory.testCommand = cmd; memory.save(ctx.root) }
        else if !ProjectMemory.isTestCommand(cmd), ProjectMemory.isBuildCommand(cmd), memory.buildCommand != cmd { memory.buildCommand = cmd; memory.save(ctx.root) }
    }

    /// Commands that exercise the code (count as verifying an edit).
    static func exercisesCode(_ cmd: String) -> Bool {
        if ProjectMemory.isTestCommand(cmd) || ProjectMemory.isBuildCommand(cmd) { return true }
        if Permissions.isReadOnly(cmd) { return false }
        let c = cmd.lowercased()
        return [#"\bpython3?\b"#, #"\bnode\b"#, #"\bruby\b"#, #"\bgo\s+run\b"#, #"\bcargo\s+run\b"#, #"\bswift\b"#, #"(^|\s)\./"#, #"\bbash\b"#,
                #"\bdeno\b"#, #"\bbun\b"#, #"\bnpx\b"#, #"\bnpm\s+run\b"#, #"\bcurl\b"#, #"\bphp\b"#, #"\bjava\b"#].contains { c.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: Completion check

    /// Runs the goal's command and file criteria (the owner's definition of done) and returns the ones not met.
    /// The results go to the judge as check output. Empty outside goal mode.
    func criteriaMisses() async -> [String] {
        guard inGoal else { return [] }
        if goalCriteria.isEmpty, let found = GoalState.criteria(in: messages) { goalCriteria = found }
        guard !goalCriteria.isEmpty else { return [] }
        var misses: [String] = []
        var lines: [String] = []
        for i in goalCriteria.indices {
            let c = goalCriteria[i]
            switch c.kind {
            case .command:
                guard let cmd = c.command else { continue }
                let r = await execute(AgentAction(tool: "shell", args: .object(["command": .string(cmd)])), label: "Check: \(c.text)")
                goalCriteria[i].met = r.result.ok
                lines.append("\(r.result.ok ? "PASS" : "FAIL") \(c.text) (`\(cmd)`): \(Fmt.clip(r.result.output, max: 1500))")
                if !r.result.ok { misses.append("\(c.text): `\(cmd)` fails (\(Fmt.line(r.result.output, 160)))") }
            case .file:
                guard let path = c.path else { continue }
                let exists = FileManager.default.fileExists(atPath: ctx.resolve(path).path)
                goalCriteria[i].met = exists
                lines.append("\(exists ? "PASS" : "FAIL") \(c.text): \(path) \(exists ? "exists" : "is missing")")
                if !exists { misses.append("\(c.text): \(path) is missing") }
            case .manual:
                continue
            }
        }
        criteriaReport = lines.joined(separator: "\n")
        return misses
    }

    /// The judge reads this request's changes and final answer. Returns its open items, or nil when no usable verdict
    /// came back (the check is skipped; a judge failure never blocks the answer).
    func judgeAnswer(goal: String, answer: String) async -> [String]? {
        let (diff, files, _) = changeContext()
        let jm = CompletionJudge.judgeModel(for: brain.model, setting: judgeSetting, available: ModelCatalog.shared.choices.map(\.id)).model
        let prompt = CompletionJudge.prompt(goal: goal, criteria: goalCriteria.map(\.text), diff: diff, files: files,
                                            lastCheck: [verifyReport, criteriaReport].filter { !$0.isEmpty }.joined(separator: "\n"),
                                            answer: answer)
        let id = UUID()
        host?.agentStepBegan(id, tool: "review", summary: "Checking it's done")
        host?.agentStatus("Checking it's done")
        let start = Date()
        let judgeBrain = brain.fork(model: jm)
        var verdict: Verdict?
        for _ in 0..<2 {
            guard let text = try? await judgeBrain.oneShot(prompt, effort: "high") else { break }
            if let v = CompletionJudge.parse(text) { verdict = v; break }
        }
        let duration = Date().timeIntervalSince(start)
        guard let verdict else {
            host?.agentStepEnded(id, status: .ok, output: "Check skipped: the judge gave no usable verdict", diffs: [], duration: duration)
            return nil
        }
        let open = verdict.open
        host?.agentStepEnded(id, status: .ok, output: open.isEmpty ? "Done" : open.map { "- \(Fmt.line($0, 300))" }.joined(separator: "\n"),
                             diffs: [], duration: duration)
        return open
    }

    // MARK: Design check

    /// Screenshots the open page at desktop and phone size, runs the cheap checks at phone size, and asks a vision model
    /// to critique it. nil when no page is open, no model can see images, or no usable critique came back.
    func designCritique(goal: String) async -> DesignCritique.Critique? {
        guard let b = ctx.browser else { return nil }
        let here = ((try? await b.evaluate("location.href")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard here.hasPrefix("http") || here.hasPrefix("file:") else { return nil }
        let id = UUID()
        host?.agentStepBegan(id, tool: "review", summary: "Design check")
        host?.agentStatus("Checking the design")
        let start = Date()
        // Put the owner's emulated size back afterwards.
#if canImport(WebKit)
        let controller = b as? BrowserController
        let before = (controller?.viewportWidth.map { Int($0) }, controller?.viewportHeight.map { Int($0) })
#else
        let before: (Int?, Int?) = (nil, nil)
#endif
        defer { _ = b.setViewport(width: before.0, height: before.1) }
        var images: [(Data, String)] = [], labels: [String] = []
        var checks: [DesignCritique.Fix] = []
        for (label, w, h) in [("desktop 1440x900", 1440, 900), ("phone 390x844", 390, 844)] {
            _ = b.setViewport(width: w, height: h)
            try? await Task.sleep(for: .milliseconds(600))   // let the layout settle at the new size
            if let shot = try? await b.screenshot(), !BrowserQA.looksBlank(shot) { images.append((shot, "image/jpeg")); labels.append("\(label), above the fold") }
            if w < 600 {
                func object(_ js: String) async -> [String: Any] {
                    guard let raw = try? await b.evaluate(js) else { return [:] }
                    return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
                }
                checks = DesignCritique.checkFixes(audit: await object(BrowserQA.auditScript), extra: await object(DesignCritique.extraChecksScript))
            }
        }
        func end(_ text: String) { host?.agentStepEnded(id, status: .ok, output: text, diffs: [], duration: Date().timeIntervalSince(start)) }
        guard !images.isEmpty else { end("Design check skipped: couldn't screenshot the page"); return nil }
        let prompt = DesignCritique.prompt(goal: goal, checks: checks.map { "[\($0.severity.rawValue)] \($0.location): \($0.change)" }, shots: labels)
        let critic = brain.fork()
        var critique: DesignCritique.Critique?
        for _ in 0..<2 {
            guard let reply = try? await critic.visionShot(prompt, images: images) else { break }
            if let c = DesignCritique.parse(reply) { critique = c; break }
        }
        guard var critique else { end("Design check skipped: no model that sees images gave a usable review"); return nil }
        critique.fixes = DesignCritique.merge(checks: checks, critic: critique.fixes)
        let shown = DesignCritique.actionable(critique.fixes)
        end(([DesignCritique.summary(score: critique.score, fixCount: shown.count)]
             + shown.map { "- [\($0.severity.rawValue)] \(Fmt.line($0.location, 80)): \(Fmt.line($0.change, 240))" }).joined(separator: "\n"))
        return critique
    }

    /// Puts the files back as they were in the design check's best round (a later fix scored worse).
    private func restoreDesignBest(_ best: [(path: String, text: String?)]) {
        for f in best {
            if let t = f.text { try? t.write(toFile: f.path, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(atPath: f.path) }
        }
        host?.agentStatus("Kept the best-scoring design")
    }

    /// The <check> and <design-check> notes leave the history once the model has answered them (the next turn doesn't need them).
    private func clearCheckNotes() {
        guard checkNotesPending else { return }
        checkNotesPending = false
        for i in messages.indices where messages[i].role == "user" {
            messages[i].parts = messages[i].parts.map { part in
                if case .text(let t) = part, t.contains("<check>") || t.contains("<design-check>") {
                    return ChatPart.text(DesignCritique.strippingNotes(CompletionJudge.strippingChecks(t)))
                }
                return part
            }
        }
    }

    // MARK: Review

    /// A second model call reads the request's diff and returns concrete problems, or nil if it looks right.
    /// The request's changes: a unified diff, the changed files' current text, and how many lines changed.
    func changeContext() -> (diff: String, files: String, lines: Int) {
        var diff = ""
        var changed = 0
        for f in checkpoint.files {
            let url = URL(fileURLWithPath: f.path)
            let now = try? String(contentsOf: url, encoding: .utf8)
            let rel = Paths.display(url, root: ctx.root)
            let u = DiffEngine.unified(old: f.original ?? "", new: now ?? "", path: rel)
            let st = DiffEngine.stats(old: f.original ?? "", new: now ?? "")
            changed += st.added + st.removed
            diff += u.isEmpty ? "" : u + "\n"
        }
        // The diff alone hides requirements stated in the unchanged parts of a file (a docstring that says what the
        // function must do, a comment, a spec in a header), so the reader also gets the changed files' current text.
        var files = ""
        for f in checkpoint.files.prefix(6) {
            let url = URL(fileURLWithPath: f.path)
            guard let now = try? String(contentsOf: url, encoding: .utf8), !now.isEmpty, files.count < 18_000 else { continue }
            files += "\n--- \(Paths.display(url, root: ctx.root)) ---\n" + Fmt.clip(now, max: 7000) + "\n"
        }
        return (diff, files, changed)
    }

    func review(_ goal: String) async -> String? {
        let (diff, files, changed) = changeContext()
        guard changed >= 3, !diff.isEmpty else { return nil }
        let id = UUID()
        host?.agentStepBegan(id, tool: "review", summary: "Review the changes")
        host?.agentStatus("Reviewing the changes")
        let start = Date()
        let prompt = """
        You are reviewing a code change another engineer made for this request:
        "\(Fmt.line(goal, 600))"

        DIFF
        \(Fmt.clip(diff, max: 24000))
        \(files.isEmpty ? "" : "\nCURRENT CONTENT OF THE CHANGED FILES (for context)\(files)")
        First list every explicit requirement: those in the request, and those stated in docstrings, comments or specs in the files above. \
        For each one, name the exact line of code that makes it true; if you can't point to a line (for example a case the code never handles), \
        it is NOT met and counts as a problem. Then report only concrete, important problems: a requirement the code doesn't meet, bugs, parts of the \
        request that are missing, edge cases the request clearly implies, leftover debug code, or changes unrelated to the request. Don't comment on style or naming, don't suggest optional improvements. \
        Be brief: at most 5 bullet points, each with the file and what is wrong. If there are no important problems, reply with exactly: LGTM
        """
        let text = (try? await brain.oneShot(prompt, effort: "low")) ?? "LGTM"
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = clean.uppercased().hasPrefix("LGTM") || (clean.count < 80 && clean.uppercased().contains("LGTM"))
        host?.agentStepEnded(id, status: .ok, output: ok ? "No problems found" : Fmt.plain(clean), diffs: [], duration: Date().timeIntervalSince(start))
        return ok ? nil : Fmt.clip(Fmt.plain(clean), max: 2500)
    }

    // MARK: Helpers for tools that need the agent

    static let repoMapTool = ToolSpec(
        name: "repo_map", kind: .read,
        signature: #"{optional "path": folder}"#,
        summary: "outline of source files and their top-level functions, classes and types (to find where things live)",
        group: .search
    ) { a, ctx in
        let root = ctx.resolve(a["path"]?.string ?? ".")
        let map = await Task.detached { RepoMap.build(root, limit: 14000) }.value
        return .ok(map.isEmpty ? "no source files with known languages under \(ctx.rel(root))" : map)
    }

    func mcpTools() -> [ToolSpec] {
        let list = ToolSpec(name: "list_mcp_servers", kind: .meta, signature: "{}",
                            summary: "the MCP servers Anvil knows (from Anvil, the project, Peep, Claude Desktop and Claude Code) and their state",
                            group: .mcp) { _, _ in .ok(MCPManager.shared.statusLines.joined(separator: "\n")) }
        let add = ToolSpec(name: "add_mcp_server", kind: .exec,
                           signature: #"{"name": str, "command": "npx"|"uvx"|path, "args": [str], optional "env": {str: str}}"#,
                           summary: "add an MCP server to Anvil's mcp.json and connect it; its tools become callable right away",
                           group: .mcp,
                           command: { a in ([a["command"]?.string ?? ""] + (a["args"]?.array?.compactMap(\.string) ?? [])).joined(separator: " ") }
        ) { [weak self] a, _ in
            guard let name = a["name"]?.string, !name.isEmpty, let command = a["command"]?.string, !command.isEmpty else { return .fail("need name and command") }
            try MCPConfigFile.upsert(name: name, command: command, args: a["args"]?.array?.compactMap(\.string) ?? [],
                                     env: (a["env"]?.object ?? [:]).compactMapValues(\.string))
            let m = MCPManager.shared
            m.start(project: m.project)
            await m.waitUntilSettled()
            guard let s = m.servers.first(where: { $0.name == name }) else { return .fail("the server didn't start; check list_mcp_servers") }
            if case .failed(let msg) = s.state { return .fail("added \(name) to mcp.json but it failed to connect: \(msg)") }
            let lines = self?.refreshTools() ?? []
            return .ok("connected \(name): \(s.state.label). Tools you can call now:\n" + (lines.isEmpty ? m.toolSpecs.filter { $0.name.hasPrefix(MCPSchema.toolName(server: name, tool: "")) }.map(\.catalogLine) : lines).joined(separator: "\n"))
        }
        return [list, add]
    }

    func exploreTool() -> ToolSpec {
        ToolSpec(name: "explore", kind: .read,
                 signature: #"{"question": str}"#,
                 summary: "a read-only helper investigates a question about the codebase in its own context and returns a short report with file paths and line numbers",
                 group: .search) { [weak self] a, _ in
            guard let self else { return .fail("unavailable") }
            guard let q = a["question"]?.string ?? a["task"]?.string ?? a["query"]?.string ?? a["value"]?.string, !q.isEmpty else { return .fail("missing question") }
            return await self.runExplorer(q)
        }
    }

    func runExplorer(_ question: String) async -> ToolResult {
        let subHost = SubagentHost(parent: host, stepID: ctx.stepID)
        let subCtx = ToolContext(root: ctx.root, processes: ctx.processes, host: subHost)
        subCtx.shellTimeout = 120
        let sub = Agent(ctx: subCtx, brain: brain.fork(model: exploreModel.isEmpty ? nil : exploreModel), subagent: true)
        sub.mode = .ask
        sub.maxSteps = 14
        sub.autoVerify = false
        sub.selfReview = false
        sub.escalationModel = ""
        let goal = """
        You are a read-only research helper for another coding agent. Investigate and answer: \(question)
        Use read and search tools (read_file, grep, glob, list_dir, repo_map, read-only shell commands). Edits and commands that change \
        anything will be declined. Don't propose a plan. Batch reads and searches. Finish with done:true and a concise report in say: \
        the direct answer, the key files with line numbers, short relevant snippets, and anything you're unsure of. At most ~300 words.
        """
        let out = await sub.run(goal: goal)
        return out.ok ? .ok("explore report:\n" + out.text) : ToolResult(ok: false, output: "explore helper stopped: " + out.text)
    }

    // MARK: One action

    struct Executed {
        var line: String
        var result: ToolResult
        var action: AgentAction
        var command: String? = nil
        /// Files were changed.
        var edited = false
        /// A command that exercises the code succeeded.
        var verified = false
    }

    /// Thrown by `withBudget` when the work ran past its budget.
    struct BudgetExceeded: Error { let seconds: Double }

    /// Runs `op` for at most `seconds`. Past that its task is cancelled and this throws BudgetExceeded.
    static func withBudget<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask { () async throws -> T in
                try await Task.sleep(for: .seconds(seconds))
                throw BudgetExceeded(seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw BudgetExceeded(seconds: seconds) }
            return first
        }
    }

    /// How long a tool may run before it is stopped. Nil for tools with their own limits or that wait on the owner.
    static func toolBudget(_ tool: String, group: ToolGroup, args: JSON) -> Double? {
        if tool == "browser_wait" { return min(60, args["timeout"]?.double ?? 10) + 10 }
        if tool.hasPrefix("browser_") { return 60 }
        if tool.hasPrefix("sim_") { return 90 }
        if group == .mcp && tool.contains(".") { return 120 }   // MCP tools are named server.tool
        if tool == "fetch_url" || tool == "web_search" { return 45 }
        return nil
    }

    func execute(_ action: AgentAction, label: String? = nil) async -> Executed {
        let argsShort = Fmt.line(action.args.compact, 160)
        guard let spec = tools[action.tool] else {
            return Executed(line: "- \(action.tool) → FAILED: unknown action. Use only the listed actions.", result: .fail("unknown"), action: action)
        }
        let id = UUID()
        ctx.stepID = id
        let summary = label ?? Self.describe(action, root: ctx.root)
        let start = Date()

        // Re-reading a file the model saw a moment ago, unchanged: point back to it instead of resending it.
        var readKey: String?
        var readDate: Date?
        if action.tool == "read_file", let p = action.args["path"]?.string ?? action.args["file"]?.string {
            let url = ctx.resolve(p)
            readKey = "\(url.path)|\(action.args["offset"]?.int ?? 1)|\(action.args["limit"]?.int ?? 400)"
            readDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let key = readKey, let d = readDate, let (seenDate, seenStep) = readCache[key], seenDate == d, seenStep < currentStep, currentStep - seenStep <= 3 {
                let msg = "unchanged since you read it at step \(seenStep) (same lines); use that output"
                host?.agentStepBegan(id, tool: action.tool, summary: summary)
                host?.agentStepEnded(id, status: .ok, output: msg, diffs: [], duration: 0)
                return Executed(line: "- read_file \(argsShort) → ok: \(msg)", result: .ok(msg), action: action)
            }
        }

        if let prepare = spec.prepare {
            host?.agentStepBegan(id, tool: action.tool, summary: summary)
            host?.agentStatus(summary)
            let changes: [FileChange]
            do { changes = try await prepare(action.args, ctx) } catch {
                let msg = (error as? ToolFailure)?.message ?? error.localizedDescription
                host?.agentStepEnded(id, status: .failed, output: msg, diffs: [], duration: Date().timeIntervalSince(start))
                return Executed(line: "- \(action.tool) \(argsShort) → FAILED: \(msg)", result: .fail(msg), action: action)
            }
            let diffs = changes.map { $0.diff(root: ctx.root) }
            let decision = Permissions.decide(mode: mode, kind: .edit, paths: changes.map(\.url), root: ctx.root, allowed: allowedCommands)
            if let denied = await gate(decision, tool: action.tool, command: nil, diffs: diffs) {
                host?.agentStepEnded(id, status: .denied, output: denied, diffs: diffs, duration: 0)
                return Executed(line: "- \(action.tool) \(argsShort) → DECLINED: \(denied)", result: .fail(denied), action: action)
            }
            do {
                for c in changes {
                    if lspChecks, lspTouched.index(forKey: c.url) == nil { lspTouched[c.url] = .some(c.old) }
                    checkpoint.record(c.url, before: c.old)
                    try c.apply()
                    ctx.readFiles.insert(c.url.standardizedFileURL.path)
                    ctx.stamp(c.url)
                    FileIndex.of(ctx.root).noteChanged(c.url, deleted: c.new == nil)
                }
            } catch {
                host?.agentStepEnded(id, status: .failed, output: error.localizedDescription, diffs: diffs, duration: Date().timeIntervalSince(start))
                return Executed(line: "- \(action.tool) \(argsShort) → FAILED: \(error.localizedDescription)", result: .fail(error.localizedDescription), action: action)
            }
            onCheckpoint?(checkpoint)
            let desc = zip(changes, diffs).map { c, d in
                c.new == nil ? "deleted \(d.path)" : c.old == nil ? "created \(d.path) (\(DiffEngine.lines(c.new ?? "").count) lines)" : "edited \(d.path) (+\(d.added) -\(d.removed))"
            }.joined(separator: "; ")
            // Syntax-check what was written, so a broken file shows up now rather than a turn later.
            var problems: [String] = []
            for (c, d) in zip(changes, diffs) where c.new != nil {
                if let e = await Diagnostics.check(c.url) { problems.append("\(d.path): \(e)") }
            }
            if !problems.isEmpty {
                let msg = desc + "\nSYNTAX CHECK FAILED (the edit was written; fix it next):\n" + problems.joined(separator: "\n")
                host?.agentStepEnded(id, status: .failed, output: msg, diffs: diffs, duration: Date().timeIntervalSince(start))
                var r = ToolResult.ok(msg)
                r.stopBatch = true
                return Executed(line: "- \(action.tool) \(Self.argsForLog(action)) → ok, but \(msg)", result: r, action: action, edited: true)
            }
            host?.agentStepEnded(id, status: .ok, output: desc, diffs: diffs, duration: Date().timeIntervalSince(start))
            var checked = changes.contains { Diagnostics.command(for: $0.url) != nil } ? " (syntax ok)" : ""
            if let note = ctx.editNote { checked += " " + note; ctx.editNote = nil }
            return Executed(line: "- \(action.tool) \(Self.argsForLog(action)) → ok: \(desc)\(checked)", result: .ok(desc), action: action, edited: true)
        }

        var kind = spec.effectiveKind(action.args)
        var command = spec.command?(action.args)
        // Stopping a process another agent or the app started is not this session's call: it goes to the owner.
        if action.tool == "stop_process", let name = action.args["name"]?.string ?? action.args["value"]?.string,
           let e = ctx.processes.entry(name), e.running, ShellTools.stopNeedsApproval(owner: e.owner, session: ctx.owner) {
            kind = .exec
            command = ShellTools.foreignStopMarker(name)
        }
        let decision = Permissions.decide(mode: mode, kind: kind, command: command, root: ctx.root, allowed: allowedCommands)
        if let denied = await gate(decision, tool: action.tool, command: command, diffs: []) {
            host?.agentStepBegan(id, tool: action.tool, summary: summary)
            host?.agentStepEnded(id, status: .denied, output: denied, diffs: [], duration: 0)
            return Executed(line: "- \(action.tool) \(argsShort) → DECLINED: \(denied)", result: .fail(denied), action: action, command: command)
        }
        host?.agentStepBegan(id, tool: action.tool, summary: summary)
        host?.agentStatus(summary)
        var r: ToolResult
        do {
            guard let run = spec.run else { throw ToolFailure("tool has no implementation") }
            if let budget = Self.toolBudget(action.tool, group: spec.group, args: action.args) {
                let context = ctx
                r = try await Self.withBudget(seconds: budget) { try await run(action.args, context) }
            } else {
                r = try await run(action.args, ctx)
            }
        } catch let b as BudgetExceeded {
            r = .fail("\(action.tool) took longer than \(Int(b.seconds)) s and was stopped. Try a different approach or a smaller step.")
        } catch is CancellationError {
            r = .fail("stopped by the owner")
        } catch {
            r = .fail((error as? ToolFailure)?.message ?? "error: \(error.localizedDescription)")
        }
        // Prefetch what's obviously next: the code a failure points to, the code around a few grep hits.
        var extra = ""
        if prefetch {
            if action.tool == "shell" && !r.ok {
                let code = Prefetch.snippets(for: r.output, root: ctx.root)
                if !code.isEmpty { extra = "\nRELEVANT CODE (where the error output points; '>' marks the line):\n" + code }
            } else if action.tool == "grep" && r.ok && action.args["context"] == nil, let code = Prefetch.grepContext(r.output, root: ctx.root) {
                extra = "\nCODE AROUND THE HITS:\n" + code
            }
        }
        // A command can exit 0 and still have failed (a build that prints errors, a runner that prints a failed test).
        if action.tool == "shell", r.ok, let line = OutputCheck.outputShowsFailure(r.output) {
            r.ok = false
            r.stopBatch = true
            r.output = "exit code 0, but the output shows a failure: \(line)\n" + r.output
        }
        if action.tool == "shell" { FileIndex.of(ctx.root).invalidate() }
        host?.agentStepEnded(id, status: r.ok ? .ok : .failed, output: r.output, diffs: [], duration: Date().timeIntervalSince(start))
        if r.ok, let key = readKey, let d = readDate { readCache[key] = (d, currentStep) }
        // A check with || can pass on the second command while the first one failed: it doesn't verify anything.
        var orNote = ""
        if action.tool == "shell", let cmd = command, Self.exercisesCode(cmd), OutputCheck.hasOrChain(cmd) {
            orNote = "\n(This command uses ||, which can hide a failing first command; run the checks separately.)"
        }
        var verified = false
        if action.tool == "shell", r.ok, let cmd = command, Self.exercisesCode(cmd), orNote.isEmpty {
            verified = true
            remember(command: cmd)
        }
        return Executed(line: "- \(action.tool) \(argsShort) → \(r.ok ? "ok" : "FAILED"): \(Fmt.clip(r.output, max: 16000))\(extra)\(orNote)", result: r, action: action, command: command, verified: verified)
    }

    /// Applies the permission decision, asking the owner when needed. Returns the refusal text, or nil to proceed.
    private func gate(_ decision: PermissionDecision, tool: String, command: String?, diffs: [FileDiff]) async -> String? {
        if command == nil { batchEditsLeft = max(0, batchEditsLeft - 1) }
        switch decision {
        case .allow: return nil
        case .deny(let why): return why
        case .ask(let reason):
            // Edits inside the project that an approved plan or a "whole reply" approval already covers.
            if command == nil && reason == "edit" && (planEditsApproved || batchEditsApproved) { return nil }
            let key = command.map(Permissions.commandKey)
            let req = PermissionRequest(tool: tool, reason: reason, command: command, diffs: diffs, commandKey: key,
                                        batchRemaining: command == nil ? batchEditsLeft : 0)
            // A dangerous command the owner approved after it was queued runs once.
            if let command, approvedOnce.contains(command) { approvedOnce.remove(command); return nil }
            // Goal mode runs unattended: a dangerous command is queued for the owner and the goal carries on.
            if let queue = queueApprovals, let command, Permissions.dangerReason(command) != nil {
                queue(req)
                return "queued for the owner's approval; carry on with other work"
            }
            host?.agentStatus("Waiting for your approval")
            let answer = await host?.agentPermission(req) ?? .deny(nil)
            switch answer {
            case .allow: return nil
            case .allowBatch:
                batchEditsApproved = true
                return nil
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
        var summary: String
        let size = Compactor.estimateTokens(messages, model: brain.model)
        if size <= Compactor.singleCallTokens {
            do { summary = try await brain.reply(Compactor.summaryRequest(messages, focus: focus)) }
            catch where Compactor.isTooLong(error) { summary = try await rollingSummary(focus: focus) }
        } else {
            summary = try await rollingSummary(focus: focus)
        }
        let clean = summary.replacingOccurrences(of: #"```json[\s\S]*?```"#, with: "", options: .regularExpression)
        if !isSubagent, AppSettings.shared.notebookMemory {
            // Only what memory doesn't have yet: the messages after the last upload (the first message is the briefing).
            let from = min(max(memoryUploadedCount?() ?? 1, 1), messages.count)
            let root = memoryRoot ?? ctx.root
            if from < messages.count {
                let day = Date().formatted(date: .abbreviated, time: .omitted)
                NotebookMemory.shared.upload(title: "\(memoryTitle ?? root.lastPathComponent) · compacted \(day)",
                                             text: NotebookMemory.transcript(Array(messages[from...])), root: root)
            }
        }
        let base = briefing.isEmpty ? (messages.first?.text ?? "") : briefing
        messages = Compactor.compacted(briefing: base, summary: clean)
        readCache = [:]
        onHistory?()
        onCompacted?(clean)
    }

    /// Summarizes the history in parts, each folded into the running summary, so no single call is bigger than
    /// the provider accepts. A part the provider still rejects as too long is split in half and retried.
    func rollingSummary(focus: String?) async throws -> String {
        let body = Array(messages.dropFirst())   // the first message is the briefing, kept separately
        let ratio = max(1.5, TokenCalibrator.shared.ratio(for: brain.model))
        var budget = Compactor.chunkTokens
        var parts = Compactor.chunks(body, maxChars: Int(Double(budget) * ratio))
        var summary: String?
        var i = 0
        var total = parts.count
        while i < parts.count {
            try Task.checkCancellation()
            host?.agentStatus("Compacting part \(i + 1) of \(total)")
            let request = Compactor.rollingRequest(summary: summary, chunk: parts[i], part: i + 1, of: total, focus: focus)
            do {
                let reply = try await brain.reply(request)
                summary = reply.replacingOccurrences(of: #"```json[\s\S]*?```"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                i += 1
            } catch where Compactor.isTooLong(error) {
                guard budget > Compactor.minChunkTokens else { throw error }
                budget /= 2
                // Re-split this part and everything after it with the smaller budget.
                let rest = parts[i...].flatMap { $0 }
                parts = Array(parts[..<i]) + Compactor.chunks(rest, maxChars: Int(Double(budget) * ratio))
                total = parts.count
            }
        }
        return summary ?? ""
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

    private func finish(_ raw: String, ok: Bool, steps: Int, silent: Bool = false, verifiedBy: String? = nil) -> AgentOutcome {
        var text = Fmt.plain(raw)
        lastRequest = (requestStart, Date(), steps)
        if ok && !isSubagent { text = checkpoint.files.isEmpty ? Self.trimFiller(text) : Self.stripLeadingPointer(text) }
        if !checkpoint.files.isEmpty { onCheckpoint?(checkpoint) }
        let changed = checkpoint.files.map { Paths.display(URL(fileURLWithPath: $0.path), root: ctx.root) }
        // Remember what broke, so the next session in this project doesn't walk into it again.
        if !ok && !isSubagent && text != "Stopped.", let f = lastFailure {
            memory.addLesson(f)
            memory.save(ctx.root)
        }
        if !silent { host?.agentSay(text, final: true) }
        host?.agentStatus("")
        return AgentOutcome(text: text, ok: ok, steps: steps, changedFiles: changed, verifiedBy: verifiedBy)
    }

    /// Drops the stock closing sentences models tack onto answers that changed nothing: "No changes were made",
    /// "the folder is not a git repo", "let me know if you want…". Only whole sentences at the very end are
    /// removed, and never the whole answer.
    /// A final answer too short to tell the owner what exists, where it is and how to use it.
    static func isThinAnswer(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 100 { return true }
        // A real summary names something concrete: a path, a command or a file.
        let concrete = t.contains("/") || t.contains("`") || [".py", ".ts", ".tsx", ".swift", ".js", ".rs", ".go", ".md", ".json"].contains { t.contains($0) }
        return !concrete && t.count < 320 && !t.contains("\n")
    }

    /// "Answered above: it's a flash loan…" → "It's a flash loan…". A pointer to text that isn't there reads as broken.
    static func stripLeadingPointer(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: #"^(answered|answer|as (shown|noted|mentioned|described)|see|per|from|based on) (above|below|the (results|search results|output|steps) above)\s*[:,.\-–—]\s*"#,
                              options: [.regularExpression, .caseInsensitive]) else { return text }
        let rest = String(t[r.upperBound...])
        guard rest.count > 20, let first = rest.first else { return text }
        return first.uppercased() + rest.dropFirst()
    }

    static func trimFiller(_ text: String) -> String {
        let text = stripLeadingPointer(text)
        let filler = [
            #"^no (files|changes|code|edits)( (were|have been))? (made|changed|modified|edited|touched)\b"#,
            #"^(i )?(made|did not make|didn't make) no (changes|edits)\b"#,
            #"^nothing (was|has been) (changed|modified|edited)\b"#,
            #"^(and )?(the|this) (folder|directory|workspace|project|repository|repo) (is not|isn't) a git repo"#,
            #"^(let me know|feel free to|if you('d| would)? (like|want)|would you like|want me to|happy to|i can also)\b"#,
            #"^(no|nothing)( further| more| else)?( actions?| steps?| changes?)?( is| are)?( needed| required| necessary| to do)\b"#,
            #"^(the )?(task|request|work) (is )?(now )?(complete|completed|done|finished)\b"#,
            #"^(i('m| am) )?(done|finished)\b[.!]?$"#,
        ]
        func isFiller(_ sentence: String) -> Bool {
            let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !s.isEmpty && filler.contains { s.range(of: $0, options: .regularExpression) != nil }
        }
        var paragraphs = text.components(separatedBy: "\n\n")
        while var last = paragraphs.last {
            // Split the final paragraph into sentences and drop filler from its end.
            var sentences = Self.sentences(last)
            var dropped = false
            while let tail = sentences.last, isFiller(tail) { sentences.removeLast(); dropped = true }
            guard dropped else { break }
            last = sentences.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if last.isEmpty { paragraphs.removeLast() } else { paragraphs[paragraphs.count - 1] = last; break }
            if paragraphs.isEmpty { return text }
        }
        let out = paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? text : out
    }

    /// Sentences with their trailing punctuation and spacing, so joining them restores the text.
    private static func sentences(_ paragraph: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(paragraph)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if ".!?".contains(c), next == " " || next == "\n" {
                // Keep "e.g." and "v1.2" together: only split before a space.
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
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
        case "browser_open": return "Open \(Fmt.line(args["url"]?.string ?? "", 100))"
        case "browser_read": return "Read the page"
        case "browser_click": return "Click [\(args["id"]?.int ?? 0)]"
        case "browser_type": return "Type into [\(args["id"]?.int ?? 0)]"
        case "browser_eval": return "Run JS in the page"
        case "browser_screenshot": return "Screenshot the page"
        case "browser_find": return "Find \u{201C}\(Fmt.line(args["text"]?.string ?? "", 60))\u{201D} on the page"
        case "browser_key": return "Press \(args["key"]?.string ?? "")"
        case "browser_select": return "Select \(Fmt.line(args["value"]?.string ?? "", 40)) in [\(args["id"]?.int ?? 0)]"
        case "browser_hover": return "Hover [\(args["id"]?.int ?? 0)]"
        case "browser_scroll": return "Scroll the page"
        case "browser_wait": return "Wait for \(Fmt.line(args["text"]?.string ?? args["selector"]?.string ?? "", 60))"
        case "browser_nav": let act = args["action"]?.string ?? "reload"; return act.prefix(1).uppercased() + act.dropFirst() + " the page"
        case "browser_console": return "Read the console"
        case "browser_viewport": return "Viewport \(args["device"]?.string ?? "\(args["width"]?.int ?? 0)px")"
        case "sim_describe": return "Read the simulator screen"
        case "sim_tap": return args["id"] != nil ? "Tap [\(args["id"]?.int ?? 0)]" : "Tap \(args["x"]?.int ?? 0),\(args["y"]?.int ?? 0)"
        case "sim_screenshot": return "Screenshot the simulator"
        case "sim_type": return "Type in the simulator"
        case "sim_run_app": return "Install and launch \(Fmt.line(args["app"]?.string ?? "", 60))"
        case "sim_boot": return "Boot \(args["device"]?.string ?? "a simulator")"
        case "repo_map": return "Map " + (path.isEmpty ? "the repo" : path)
        case "explore": return "Explore: \(Fmt.line(args["question"]?.string ?? args["task"]?.string ?? "", 110))"
        case "use_skill": return "Use skill \(args["name"]?.string ?? "")"
        case "ask_user": return "Ask: \(Fmt.line(args["question"]?.string ?? "", 100))"
        default: return "\(a.tool) \(Fmt.line(args.compact, 100))"
        }
    }

    /// "I'll read the file first." with no actions: the model meant to act, it isn't an answer.
    /// What the model should do next when a reply without actions is a progress note rather than the end of the request,
    /// or nil when it really is the end. Mid-plan notes name the next milestone. A question to the owner always ends the turn.
    nonisolated static func nextStep(done: Bool, explicitDone: Bool, planSteps: [String], milestonesDone: Int, text: String) -> String? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") { return nil }
        if !done, !planSteps.isEmpty, milestonesDone < planSteps.count {
            return "milestone \(milestonesDone + 1): \(planSteps[milestonesDone])"
        }
        if explicitDone && !done { return "the next step of the request" }
        return nil
    }

    /// An answer that only introduces content it doesn't include: "Here are some ideas for X." with no list after it.
    static func announcesContent(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard !t.isEmpty, t.count < 300, !t.contains("\n") else { return false }
        // "Here are a few angles:" ends where the content should start.
        if t.hasSuffix(":") { return t.split(separator: " ").count <= 25 }
        // "Here are unconventional ideas for X." announces a set of things; "Here's what happened: the token expired." gives the answer.
        let intro = ["here are ", "here's ", "here is ", "below are ", "below is ", "the following ", "these are ", "following are "]
        guard intro.contains(where: { t.hasPrefix($0) }), !t.dropLast().contains(":") else { return false }
        let sets = ["ideas", "options", "steps", "ways", "tips", "angles", "suggestions", "examples", "strategies", "approaches",
                    "alternatives", "reasons", "things", "points", "methods", "tactics", "recommendations", "changes", "list"]
        return sets.contains { t.contains($0) }
    }

    static func announcesIntent(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard t.count < 400 else { return false }
        let starts = ["i'll ", "i will ", "let me ", "let's ", "i'm going to ", "i am going to ", "first, i", "next, i", "now i'll", "now let me", "i need to "]
        if starts.contains(where: { t.hasPrefix($0) }) || t.hasSuffix(":") { return true }
        // "...state machine. I'll implement that behavior and check it." : the last sentence is a promise.
        // Sentences end at punctuation followed by a space, so "index.html" stays whole; "Small tweak: I'll ..." counts too.
        let clauses = t.components(separatedBy: CharacterSet(charactersIn: "\n")).flatMap { $0.components(separatedBy: ". ") }
            .flatMap { $0.components(separatedBy: ": ") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let last = clauses.last ?? ""
        return ["i'll ", "i will ", "let me ", "next i'll", "now i'll"].contains { last.hasPrefix($0) }
    }

    /// "I can't access your files / run commands here": the model thinks it's a plain chat.
    /// The request asks for changes to the project (not a question or a chat).
    static func asksForWork(_ goal: String) -> Bool {
        let g = " " + goal.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let verbs = ["make", "build", "create", "add", "fix", "implement", "write", "refactor", "update", "change", "remove",
                     "delete", "rename", "set up", "setup", "install", "migrate", "port", "convert", "generate", "scaffold", "redesign"]
        return verbs.contains { g.contains(" \($0) ") || g.contains(" \($0)s ") || g.range(of: "^\\W*\($0)\\b", options: .regularExpression, range: g.range(of: g)) != nil }
    }

    static func looksLikeCantAct(_ raw: String) -> Bool {
        // The excuse comes first, even when a long plan or code dump follows it.
        let full = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "without direct access", with: "without access")
            .replacingOccurrences(of: "no direct access", with: "no access")
        // The excuse comes at the start (before a plan) or the end (a closing note): read both.
        let t = full.count <= 1400 ? full : String(full.prefix(700)) + " … " + String(full.suffix(700))
        if t.contains("retriever:") || t.contains("tool declarations") { return true }
        let cant = ["can't", "cannot", "can not", "unable to", "don't have", "do not have", "no access", "not able to",
                    "aren't available", "are not available", "isn't available", "is not available", "not available to me",
                    "no tools", "without access", "lack access", "lack the"]
        let what = ["access", "run commands", "execute", "read files", "the files", "your files", "file system", "filesystem", "the project", "browse",
                    "tools", "shell", "terminal", "browser", "this environment", "sandbox"]
        let sandboxed = t.contains("sandboxed environment") || t.contains("running in a sandbox")
        return sandboxed || (cant.contains { t.contains($0) } && what.contains { t.contains($0) })
    }

    /// Whether a failed action says something about the model's work (edits, builds, tests, runs), not the environment:
    /// browsing, network, waiting, looking for files and actions the owner declined don't count toward a model switch.
    static func countsTowardEscalation(tool: String, command: String?, output: String, declined: Bool) -> Bool {
        if declined { return false }
        if tool == "shell" {
            guard let cmd = command, exercisesCode(cmd) else { return false }
            return !output.contains("command not found")
        }
        return ["edit_file", "multi_edit", "write_file", "replace_lines", "delete_file"].contains(tool)
    }

    /// "Previous request: started 10:02:11, finished 10:05:59 (3 min 48 s), 14 steps." for follow-up turns.
    static func previousRequestLine(start: Date, end: Date, steps: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let secs = max(0, Int(end.timeIntervalSince(start)))
        let dur = secs >= 60 ? "\(secs / 60) min \(secs % 60) s" : "\(secs) s"
        return "Previous request: started \(f.string(from: start)), finished \(f.string(from: end)) (\(dur)), \(steps) step\(steps == 1 ? "" : "s")."
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

/// Host for an explore helper: its steps show as output lines under the parent's explore step; it can't ask for anything.
final class SubagentHost: AgentHost {
    weak var parent: AgentHost?
    let stepID: UUID?
    init(parent: AgentHost?, stepID: UUID?) { self.parent = parent; self.stepID = stepID }

    func agentStatus(_ text: String) {}
    func agentThought(_ text: String) {}
    func agentSay(_ text: String, final: Bool) {}
    func agentStepBegan(_ id: UUID, tool: String, summary: String) {
        if let stepID { parent?.agentStepOutput(stepID, chunk: "↳ \(summary)\n") }
    }
    func agentStepOutput(_ id: UUID, chunk: String) {}
    func agentStepEnded(_ id: UUID, status: ToolStep.Status, output: String, diffs: [FileDiff], duration: Double) {}
    func agentPermission(_ req: PermissionRequest) async -> PermissionAnswer { .deny("this is a read-only helper; report what you found instead") }
    func agentPlan(_ steps: [String]) async -> PlanDecision { .approve }
    func agentMilestone(_ index: Int) {}
    func agentTodos(_ todos: [TodoItem]) {}
    func agentAsk(_ question: String) async -> String? { nil }
    func agentDrainSteering() -> [String] { [] }
    func agentError(_ text: String) {}
}
