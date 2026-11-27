import Foundation

nonisolated struct TodoItem: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case pending, inProgress = "in_progress", completed }
    var id = UUID()
    var content: String
    var status: Status
}

nonisolated struct ToolStep: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case running, ok, failed, denied }
    var name: String
    var summary: String
    var status: Status
    var output: String = ""
    var diffs: [FileDiff] = []
    var duration: Double?
}

nonisolated struct PlanCard: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case pending, approved, revised, cancelled }
    var steps: [String]
    var done: [Int] = []          // 1-based milestones finished
    var state: State = .pending
}

/// One row of the conversation as the owner sees it.
nonisolated struct ChatItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case user, assistant, thought, tool, plan, system, error, suggestion }
    var id = UUID()
    var kind: Kind
    var text: String
    var date = Date()
    var tool: ToolStep?
    var plan: PlanCard?
    var images = 0
    /// For an assistant reply: true when it is the final answer of a request.
    var final = false
    /// For a user message that started a request: how many model messages existed before it (for rewinding).
    var historyIndex: Int?
    /// For a final answer: the request did enough work to be worth saving as a skill.
    var skillWorthy = false
    /// For a suggestion: what accepting it does.
    var suggestion: Suggestion?
}

nonisolated struct Suggestion: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case convention }
    enum State: String, Codable, Sendable { case open, accepted, dismissed }
    var kind: Kind
    var state: State = .open
}

nonisolated struct SessionUsage: Codable, Equatable, Sendable {
    var calls = 0
    var prompt = 0
    var completion = 0
    var cached = 0
    var cost = 0.0
    var lastPrompt = 0     // size of the most recent request (how full the context is)
    var lastCached = 0     // how much of the most recent request the provider served from its cache

    mutating func add(_ u: ChatUsage, cost c: Double?) {
        calls += 1; prompt += u.prompt; completion += u.completion; cached += u.cached; cost += c ?? 0; lastPrompt = u.prompt; lastCached = u.cached
    }
    var line: String {
        guard calls > 0 else { return "no calls yet" }
        return "\(Fmt.dollars(cost)) · \(Fmt.tokens(prompt + completion)) tokens · \(calls) calls"
    }
}

/// Everything persisted about one conversation in one project.
nonisolated struct Session: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title = "New session"
    var created = Date()
    var updated = Date()
    var projectPath: String
    var model: String?
    var mode: PermissionMode?
    var items: [ChatItem] = []
    /// The model conversation (text only once saved).
    var messages: [ChatMessage] = []
    /// The fixed briefing that opened this conversation (reused when compacting).
    var briefing: String = ""
    var todos: [TodoItem] = []
    var plan: PlanCard?
    var checkpoints: [Checkpoint] = []
    var usage = SessionUsage()
    var allowedCommands: [String] = []
    /// Worktree sessions run in their own git worktree on their own branch.
    var workdir: String?
    var branch: String?
    var baseBranch: String?
    /// Set for a sub-session started by another session's agent (spawn_session).
    var parentID: UUID?
    /// The short name the parent uses for this sub-session.
    var subName: String?
    /// Per-session limits for each request (nil = the app-wide settings).
    var costLimit: Double?
    var stepLimit: Int?
    /// Tool names the model was told about (so tools added later, e.g. by an Anvil update, get announced).
    var briefedTools: [String]?
    /// When the conversation was last compacted (rewinding to before this can restore files but not the conversation).
    var compactedAt: Date?
    /// The worktree and branch were removed by Worktree cleanup; the conversation stays as history.
    var worktreeRemoved = false
    /// The NotebookLM notebook that ask_memory queries in this session instead of the project's memory (/notebook).
    var attachedNotebook: String?
    var attachedNotebookTitle: String?
    /// How many messages of the conversation are already in NotebookLM memory (nil = none yet).
    var memoryUploadedCount: Int?
    /// The /goal mission this session runs or ran (nil = none).
    var goal: GoalState?
    /// The "judge runs on a different model" note was shown in this session.
    var judgeNoteShown: Bool?

    /// Where the agent works: the worktree for worktree sessions, else the project.
    var root: URL { URL(fileURLWithPath: workdir ?? projectPath) }

    static func == (a: Session, b: Session) -> Bool { a.id == b.id && a.updated == b.updated && a.items.count == b.items.count }

    /// A short title from the first request.
    static func title(from goal: String) -> String {
        let one = goal.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let words = one.split(separator: " ").prefix(8).joined(separator: " ")
        return words.count > 60 ? String(words.prefix(57)) + "..." : (words.isEmpty ? "New session" : words)
    }

    /// The title a model wrote: first line, wrapping quotes and a "Title:" label removed. Nil when empty or over 12 words.
    static func cleanTitle(_ raw: String) -> String? {
        // Models that always answer in Anvil's reply format send {"say": "Title"} in a ```json fence: use the text inside.
        if let open = raw.range(of: "{"), let close = raw.range(of: "}", options: .backwards), open.lowerBound < close.lowerBound,
           let data = String(raw[open.lowerBound...close.lowerBound]).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = (obj["title"] ?? obj["say"] ?? obj["answer"]) as? String, inner != raw {
            return cleanTitle(inner)
        }
        // A bare fence or its language tag ("```json", "json") is never a title.
        let lines = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("```") && !["json", "text", "markdown", "plaintext"].contains($0.lowercased()) }
        if lines.count != raw.split(whereSeparator: \.isNewline).count { return cleanTitle(lines.joined(separator: "\n")) }
        let wrap = CharacterSet(charactersIn: "\"'`*#\u{201C}\u{201D}\u{2018}\u{2019} ")
        var line = raw.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: wrap) }.first { !$0.isEmpty } ?? ""
        if line.lowercased().hasPrefix("title:") { line = String(line.dropFirst(6)).trimmingCharacters(in: wrap) }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")).trimmingCharacters(in: wrap)
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty, line.split(separator: " ").count <= 12 else { return nil }
        return line.count > 60 ? String(line.prefix(60)).trimmingCharacters(in: .whitespaces) : line
    }

    /// The user item that started the request in flight (the last one with a model history position).
    static func inFlightIndex(_ items: [ChatItem]) -> Int? {
        items.lastIndex { $0.kind == .user && $0.historyIndex != nil }
    }

    /// What a fork keeps of a conversation before the request at `idx`: its items and model messages.
    /// The messages are empty when they can't be trusted (fewer than the request expects, or compacted after it).
    static func forkPrefix(_ source: Session, before idx: Int) -> (items: [ChatItem], messages: [ChatMessage], keepsConversation: Bool) {
        let item = source.items[idx]
        let items = Array(source.items.prefix(idx))
        let ok = item.historyIndex.map { $0 <= source.messages.count } == true && !(source.compactedAt.map { $0 > item.date } ?? false)
        guard ok, let h = item.historyIndex else { return (items, [], false) }
        return (items, Array(source.messages.prefix(h)), true)
    }
}

nonisolated struct SessionSummary: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var updated: Date
    var cost: Double
    var branch: String? = nil
    /// Set for a sub-session: the session whose agent started it.
    var parentID: UUID? = nil
    var workdir: String? = nil
    var worktreeRemoved = false
    /// The raw phase of the session's goal (nil = no goal), for the sidebar's scope symbol.
    var goalPhase: String? = nil
}

/// Sessions are JSON files under Application Support/Anvil/projects/<project-key>/sessions.
nonisolated enum SessionStore {
    static func projectKey(_ root: URL) -> String {
        let path = root.standardizedFileURL.path
        var hash: UInt64 = 1469598103934665603
        for b in path.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let name = root.lastPathComponent.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(name.prefix(40)) + "-" + String(hash, radix: 16).prefix(10)
    }

    static func folder(for root: URL) -> URL {
        Paths.dir(Paths.sub("projects").appendingPathComponent(projectKey(root)).appendingPathComponent("sessions"))
    }

    static func file(_ id: UUID, root: URL) -> URL { folder(for: root).appendingPathComponent("\(id.uuidString).json") }

    static func save(_ s: Session) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(s)
        try data.write(to: file(s.id, root: URL(fileURLWithPath: s.projectPath)), options: .atomic)
    }

    static func load(_ id: UUID, root: URL) -> Session? {
        guard let data = try? Data(contentsOf: file(id, root: root)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Session.self, from: data)
    }

    static func list(root: URL) -> [SessionSummary] {
        let dir = folder(for: root)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            (try? Data(contentsOf: f)).flatMap { summary(from: $0) }
        }.sorted { $0.updated > $1.updated }
    }

    /// The list's fields, read from a session file's head (a goal's phase only when the file has a goal).
    static func summary(from data: Data) -> SessionSummary? {
        struct GoalHead: Decodable { var phase: String? }
        struct Head: Decodable { var id: UUID; var title: String; var updated: Date; var usage: SessionUsage?; var branch: String?; var parentID: UUID?; var workdir: String?; var worktreeRemoved: Bool?; var goal: GoalHead? }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let h = try? dec.decode(Head.self, from: data) else { return nil }
        return SessionSummary(id: h.id, title: h.title, updated: h.updated, cost: h.usage?.cost ?? 0, branch: h.branch,
                              parentID: h.parentID, workdir: h.workdir, worktreeRemoved: h.worktreeRemoved ?? false,
                              goalPhase: h.goal?.phase)
    }

    /// Moves the session file to the Trash (recoverable), falling back to deleting it.
    static func delete(_ id: UUID, root: URL) {
        let f = file(id, root: root)
        if (try? FileManager.default.trashItem(at: f, resultingItemURL: nil)) == nil { try? FileManager.default.removeItem(at: f) }
    }
}

/// Recently opened project folders.
enum RecentProjects {
    static func list() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func add(_ u: URL) {
        var l = list().map(\.path).filter { $0 != u.path }
        l.insert(u.path, at: 0)
        UserDefaults.standard.set(Array(l.prefix(12)), forKey: "recentProjects")
    }
}
