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

    mutating func add(_ u: ChatUsage, cost c: Double?) {
        calls += 1; prompt += u.prompt; completion += u.completion; cached += u.cached; cost += c ?? 0; lastPrompt = u.prompt
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

    /// Where the agent works: the worktree for worktree sessions, else the project.
    var root: URL { URL(fileURLWithPath: workdir ?? projectPath) }

    static func == (a: Session, b: Session) -> Bool { a.id == b.id && a.updated == b.updated && a.items.count == b.items.count }

    /// A short title from the first request.
    static func title(from goal: String) -> String {
        let one = goal.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let words = one.split(separator: " ").prefix(8).joined(separator: " ")
        return words.count > 60 ? String(words.prefix(57)) + "..." : (words.isEmpty ? "New session" : words)
    }
}

nonisolated struct SessionSummary: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var updated: Date
    var cost: Double
    var branch: String? = nil
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
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        struct Head: Decodable { var id: UUID; var title: String; var updated: Date; var usage: SessionUsage?; var branch: String? }
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let d = try? Data(contentsOf: f), let h = try? dec.decode(Head.self, from: d) else { return nil }
            return SessionSummary(id: h.id, title: h.title, updated: h.updated, cost: h.usage?.cost ?? 0, branch: h.branch)
        }.sorted { $0.updated > $1.updated }
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
