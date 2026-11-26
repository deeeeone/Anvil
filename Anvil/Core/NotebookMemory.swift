import Foundation
import Observation

/// The Google AI plan, which sets NotebookLM's limits (notebooks, sources per notebook, chats per day).
nonisolated enum NotebookPlan: String, CaseIterable, Sendable {
    case free, plus, pro, ultra

    static func named(_ raw: String) -> NotebookPlan { NotebookPlan(rawValue: raw) ?? .free }

    var notebooks: Int {
        switch self {
        case .free: return 100
        case .plus: return 200
        case .pro, .ultra: return 500
        }
    }
    var sources: Int {
        switch self {
        case .free: return 50
        case .plus: return 100
        case .pro: return 300
        case .ultra: return 500
        }
    }
    var chats: Int {
        switch self {
        case .free: return 50
        case .plus: return 200
        case .pro: return 500
        case .ultra: return 2500
        }
    }
    /// Agent questions per day: 80% of the plan's chats, leaving room for the owner's own use.
    var askCap: Int { chats * 4 / 5 }
    /// Sources are evicted once a notebook reaches this many (five slots stay free).
    var evictAt: Int { sources - 5 }
}

/// One day's count of questions asked with an account.
nonisolated struct DailyCount: Codable, Equatable, Sendable {
    var day = ""
    var count = 0
}

/// The pure decisions behind NotebookLM memory: when a session uploads, when the agent is offered ask_memory,
/// and how much of the daily question budget is left.
nonisolated enum MemoryRules {
    static let uploadTokens = 60_000
    static let uploadChars = 40_000

    /// yyyy-MM-dd in the local calendar.
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func budgetLeft(_ used: DailyCount, today: String, limit: Int) -> Int {
        max(0, limit - (used.day == today ? used.count : 0))
    }

    static func spend(_ used: DailyCount, today: String) -> DailyCount {
        DailyCount(day: today, count: (used.day == today ? used.count : 0) + 1)
    }

    /// A session uploads once it is long (about 60k tokens) and has at least 40k characters not yet saved.
    static func shouldUpload(tokens: Int, freshChars: Int) -> Bool {
        tokens >= uploadTokens && freshChars >= uploadChars
    }

    /// ask_memory is offered when a notebook is attached, or memory is on and this session has saved or been
    /// compacted, or the session is long and the project's notebook already holds earlier sessions.
    static func offerTool(attached: Bool, uploaded: Bool, tokens: Int, notebookHasUploads: Bool, memoryOn: Bool) -> Bool {
        if attached { return true }
        guard memoryOn else { return false }
        return uploaded || (tokens >= uploadTokens && notebookHasUploads)
    }
}

/// Long-term memory: session transcripts (keys and tokens removed) go into a NotebookLM notebook in the owner's
/// Google account, and `ask_memory` asks it back. Uploads are no-ops unless the setting is on and a Google account exists.
@MainActor
@Observable
final class NotebookMemory {
    static let shared = NotebookMemory()

    /// What is kept per Google account: notebook ids by scope (the project path, or "account"), the sources Anvil
    /// added to each notebook (oldest first), and the daily question count.
    struct Store: Codable {
        var notebooks: [String: [String: String]] = [:]
        var uploads: [String: [String]] = [:]
        var dailyAsks: [String: DailyCount] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            notebooks = try c.decodeIfPresent([String: [String: String]].self, forKey: .notebooks) ?? [:]
            uploads = try c.decodeIfPresent([String: [String]].self, forKey: .uploads) ?? [:]
            dailyAsks = try c.decodeIfPresent([String: DailyCount].self, forKey: .dailyAsks) ?? [:]
        }

        enum Keys: String, CodingKey { case notebooks, uploads, dailyAsks }
    }

    private(set) var lastError = ""
    @ObservationIgnored private var store: Store
    @ObservationIgnored private var inFlight: [String: Task<String, Error>] = [:]
    /// One client per Google account, so its session (cookies and tokens) lasts for the app's lifetime.
    @ObservationIgnored private var clients: [UUID: (cookies: [String: String], client: NotebookLMClient)] = [:]

    private static var file: URL { Paths.support.appendingPathComponent("notebooklm.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        } else {
            store = Store()
        }
    }

    // MARK: Accounts and scopes

    /// Accounts NotebookLM turned away, with the cookies it saw (signing in again changes them and earns a retry).
    /// Gemini works on its session cookie alone, but NotebookLM's sign-in hand-off also needs Google's own
    /// accounts.google.com cookies, which some saved sign-ins don't have.
    @ObservationIgnored private var refused: [UUID: [String: String]] = [:]

    /// The account memory will most likely use, without asking Google: the first one not turned away.
    private var account: WebAccount? {
        WebAccounts.shared.candidates(for: .gemini).first { refused[$0.id] == nil || refused[$0.id] != WebAccounts.shared.cookies($0.id) }
    }

    var plan: NotebookPlan { NotebookPlan.named(AppSettings.shared.notebookPlan) }

    /// A client for the first Google account NotebookLM accepts: the active Gemini account first, then the others.
    private func makeClient() async throws -> (NotebookLMClient, UUID) {
        let accounts = WebAccounts.shared.candidates(for: .gemini)
        guard !accounts.isEmpty else {
            throw BrainError(status: 401, code: "unauthorized", message: "Sign in to Gemini with a Google account first. NotebookLM uses that account.")
        }
        var lastRefusal: Error?
        for account in accounts {
            let cookies = WebAccounts.shared.cookies(account.id)
            guard !cookies.isEmpty, refused[account.id] != cookies else { continue }
            if let cached = clients[account.id], cached.cookies == cookies { return (cached.client, account.id) }
            let client = NotebookLMClient(cookies: cookies)
            do {
                try await client.establishSession()
            } catch let e as BrainError where e.code == "unauthorized" {
                refused[account.id] = cookies
                lastRefusal = e
                continue
            }
            clients[account.id] = (cookies, client)
            return (client, account.id)
        }
        throw lastRefusal ?? BrainError(status: 401, code: "unauthorized",
            message: "None of your Google accounts could open NotebookLM. In Settings → Provider, add a Gemini account with \"Use Safari\" (that sign-in carries the cookies NotebookLM needs).")
    }

    /// The scope key: "account" for one notebook for everything, else the project's path.
    func scopeKey(for root: URL) -> String {
        AppSettings.shared.notebookScope == "account" ? "account" : root.standardizedFileURL.path
    }

    static func title(scope: String, root: URL) -> String {
        scope == "account" ? "Anvil memory" : "Anvil memory: \(root.lastPathComponent)"
    }

    /// A short line for a failure the owner should read.
    static func message(_ error: Error) -> String {
        (error as? BrainError)?.message ?? error.localizedDescription
    }

    /// Whether the project's notebook already holds sources saved by earlier sessions.
    func hasUploads(root: URL) -> Bool {
        guard let account, let nb = store.notebooks[account.id.uuidString]?[scopeKey(for: root)] else { return false }
        return !(store.uploads[nb] ?? []).isEmpty
    }

    // MARK: Notebooks

    /// Every notebook in the account (for `/notebook` and the connection test).
    func notebooks() async throws -> [NotebookLMClient.Notebook] {
        let (client, _) = try await makeClient()
        return try await client.listNotebooks()
    }

    /// The notebook for this project (or the account). Found by its saved id, else by its title, else created.
    /// Concurrent callers for the same scope share one lookup.
    func notebook(for root: URL) async throws -> String {
        let (client, accountID) = try await makeClient()
        let scope = scopeKey(for: root)
        if let id = store.notebooks[accountID.uuidString]?[scope] { return id }
        let key = accountID.uuidString + "|" + scope
        if let task = inFlight[key] { return try await task.value }
        let title = Self.title(scope: scope, root: root)
        let task = Task { () throws -> String in
            if let hit = try await client.listNotebooks().first(where: { $0.title == title }) { return hit.id }
            return try await client.createNotebook(title: title)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let id = try await task.value
        store.notebooks[accountID.uuidString, default: [:]][scope] = id
        save()
        return id
    }

    // MARK: Uploads

    /// Saves text as a source in this project's notebook. Fire-and-forget: a failure is kept in `lastError` and
    /// `onFailure` runs so the caller can retry the same messages later.
    func upload(title: String, text: String, root: URL, onFailure: (() -> Void)? = nil) {
        guard AppSettings.shared.notebookMemory, account != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do { try await self.uploadNow(title: title, text: text, root: root) }
            catch {
                self.lastError = Fmt.line(Self.message(error), 200)
                onFailure?()
            }
        }
    }

    /// Redacts and uploads one source, first dropping our oldest upload if the notebook is at the plan's limit.
    /// Long text keeps its newest end, since that is what a question is most likely about.
    func uploadNow(title: String, text: String, root: URL) async throws {
        let clean = String(Redactor.redact(text).suffix(NotebookLMClient.maxSourceChars))
        let nb = try await notebook(for: root)
        let (client, _) = try await makeClient()
        let current = try await client.sources(notebook: nb).count
        for id in NotebookLMClient.sourcesToEvict(count: current, recorded: store.uploads[nb] ?? [], keep: plan.evictAt) {
            try? await client.deleteSource(id)
            store.uploads[nb]?.removeAll { $0 == id }
        }
        let id = try await client.addTextSource(notebook: nb, title: Fmt.line(Redactor.redact(title), 200), text: clean)
        store.uploads[nb, default: []].append(id)
        save()
        lastError = ""
    }

    /// The conversation as plain text: each message under its speaker.
    static func transcript(_ messages: [ChatMessage]) -> String {
        messages.map { "[\($0.role == "user" ? "owner/app" : "assistant")]\n\($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: Questions

    /// Asks the attached notebook when `override` is set, else this project's memory (which must already exist).
    /// Every question counts against the account's daily budget.
    func ask(_ question: String, root: URL, notebook override: String? = nil) async throws -> String {
        let (client, accountID) = try await makeClient()
        let nb: String
        if let override {
            nb = override
        } else {
            guard AppSettings.shared.notebookMemory else {
                throw BrainError(status: 0, code: "disabled", message: "Memory is off. Turn on Remember past sessions in Settings, then Memory (NotebookLM).")
            }
            guard let id = store.notebooks[accountID.uuidString]?[scopeKey(for: root)] else {
                throw BrainError(status: 0, code: "empty", message: "Nothing has been saved to memory for this project yet.")
            }
            nb = id
        }
        let today = MemoryRules.day(Date())
        let used = store.dailyAsks[accountID.uuidString] ?? DailyCount()
        let cap = plan.askCap
        guard MemoryRules.budgetLeft(used, today: today, limit: cap) > 0 else {
            throw BrainError(status: 429, code: "budget",
                             message: "NotebookLM's daily question budget is used up (\(cap)/day); continue from the conversation and files.")
        }
        store.dailyAsks[accountID.uuidString] = MemoryRules.spend(used, today: today)
        save()
        return try await client.ask(notebook: nb, question: question)
    }

    // MARK: Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}
