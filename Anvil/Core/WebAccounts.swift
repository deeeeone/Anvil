import Foundation
import Observation
import WebKit

/// One day of calls made with a web account.
nonisolated struct WebUsageDay: Codable, Equatable, Sendable {
    var calls = 0
    var prompt = 0
    var completion = 0
    var errors = 0

    mutating func add(prompt p: Int, completion c: Int, error: Bool) {
        if error { errors += 1 } else { calls += 1 }
        prompt += p
        completion += c
    }
    var tokens: Int { prompt + completion }
}

/// A signed-in ChatGPT or Gemini web account. Cookies live in the Keychain, not in this record.
nonisolated struct WebAccount: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var provider: Provider
    var name: String
    /// Email, plan or another hint from the site (never a cookie).
    var detail = ""
    var added = Date()
    var lastUsed: Date?
    var lastError = ""
    var lastErrorAt: Date?
    var enabled = true
    /// Keyed by yyyy-MM-dd, oldest trimmed.
    var usage: [String: WebUsageDay] = [:]

    var todayKey: String { WebAccount.day.string(from: Date()) }

    var callsToday: Int { usage[todayKey]?.calls ?? 0 }
    var tokensToday: Int { usage[todayKey]?.tokens ?? 0 }
    var callsTotal: Int { usage.values.reduce(0) { $0 + $1.calls } }
    var tokensTotal: Int { usage.values.reduce(0) { $0 + $1.tokens } }
    var errorsTotal: Int { usage.values.reduce(0) { $0 + $1.errors } }

    var week: WebUsageDay {
        var sum = WebUsageDay()
        for offset in 0..<7 {
            guard let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            if let u = usage[WebAccount.day.string(from: d)] {
                sum.calls += u.calls; sum.prompt += u.prompt; sum.completion += u.completion; sum.errors += u.errors
            }
        }
        return sum
    }

    /// The address this account signed in with, when the site told us.
    var email: String {
        for candidate in [name, detail.components(separatedBy: " · ").first ?? ""] where candidate.contains("@") {
            return candidate.trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    /// Failed in the last three days and hasn't worked since.
    var needsAttention: Bool {
        guard let at = lastErrorAt, !lastError.isEmpty else { return false }
        return Date().timeIntervalSince(at) < 72 * 3600
    }

    var label: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        if !detail.isEmpty { return detail }
        return provider == .chatgpt ? "ChatGPT account" : "Google account"
    }

    var lastUsedLabel: String? {
        guard let lastUsed else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: lastUsed, relativeTo: Date())
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// The accounts Anvil can use, the active one per provider, and how much each has been used.
/// A request starts on the active account and falls through to the others when one fails.
@Observable
final class WebAccounts {
    static let shared = WebAccounts()

    private(set) var accounts: [WebAccount] = []
    private(set) var active: [Provider: UUID] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var loadError: String?

    private static var file: URL { Paths.support.appendingPathComponent("web-accounts.json") }

    private init() { load() }

    var lastLoadError: String? { loadError }

    func accounts(for provider: Provider) -> [WebAccount] {
        accounts.filter { $0.provider == provider }
    }

    func hasAny(_ provider: Provider) -> Bool {
        accounts.contains { $0.provider == provider && $0.enabled }
    }

    func account(_ id: UUID?) -> WebAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    /// The active account first, then the others (most recently added first).
    func candidates(for provider: Provider) -> [WebAccount] {
        let list = accounts(for: provider).filter(\.enabled)
        let chosen = active[provider]
        return list.sorted { a, b in
            if a.id == chosen { return true }
            if b.id == chosen { return false }
            return a.added > b.added
        }
    }

    func isActive(_ id: UUID) -> Bool { account(id).map { active[$0.provider] == $0.id } ?? false }

    func select(_ id: UUID) {
        guard let a = account(id) else { return }
        active[a.provider] = id
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].name = name
        save()
    }

    func setDetail(_ id: UUID, _ detail: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].detail = detail
        save()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].enabled = on
        if !on, active[accounts[i].provider] == id {
            let p = accounts[i].provider
            active[p] = accounts(for: p).first { $0.id != id && $0.enabled }?.id
        }
        save()
    }

    /// Saves a verified sign-in. Signing in again as the same person (or reconnecting a specific
    /// account) refreshes that account instead of adding a duplicate. Returns the account's id.
    @discardableResult
    func save(_ signIn: WebSignIn.Verified, provider: Provider, replacing: UUID? = nil) -> UUID {
        let email = signIn.email.lowercased()
        let existing = replacing.flatMap { id in accounts.firstIndex { $0.id == id } }
            ?? (email.isEmpty ? nil : accounts.firstIndex { $0.provider == provider && $0.email.lowercased() == email })
        let id: UUID
        if let i = existing {
            id = accounts[i].id
            Keychain.set(Self.cookiesJSON(signIn.cookies), for: "cookies.\(id.uuidString)")
            if !signIn.detail.isEmpty { accounts[i].detail = signIn.detail }
            accounts[i].enabled = true
            accounts[i].lastError = ""
            accounts[i].lastErrorAt = nil
            if active[provider] == nil { active[provider] = id }
            save()
        } else {
            id = signIn.accountID
            add(provider: provider, name: signIn.email, detail: signIn.detail, cookies: signIn.cookies, id: id)
        }
        Task { await ModelCatalog.shared.refresh() }
        return id
    }

    func add(provider: Provider, name: String, detail: String, cookies: [String: String], id: UUID = UUID()) {
        let account = WebAccount(id: id, provider: provider, name: name.trimmingCharacters(in: .whitespaces), detail: detail)
        Keychain.set(Self.cookiesJSON(cookies), for: "cookies.\(account.id.uuidString)")
        accounts.append(account)
        if active[provider] == nil { active[provider] = account.id }
        save()
    }

    func delete(_ id: UUID) {
        guard let a = account(id) else { return }
        Keychain.set(nil, for: "cookies.\(id.uuidString)")
        accounts.removeAll { $0.id == id }
        if active[a.provider] == id { active[a.provider] = accounts(for: a.provider).first?.id }
        save()
    }

    func cookies(_ id: UUID) -> [String: String] {
        guard let s = Keychain.get("cookies.\(id.uuidString)"), let data = s.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    /// Called by the clients when the site rotates cookies.
    func updateCookies(_ id: UUID, _ cookies: [String: String]) {
        guard !cookies.isEmpty, accounts.contains(where: { $0.id == id }) else { return }
        Keychain.set(Self.cookiesJSON(cookies), for: "cookies.\(id.uuidString)")
    }

    func record(_ id: UUID, prompt: Int, completion: Int, error: String? = nil) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let key = WebAccount.day.string(from: Date())
        var day = accounts[i].usage[key] ?? WebUsageDay()
        day.add(prompt: prompt, completion: completion, error: error != nil)
        accounts[i].usage[key] = day
        accounts[i].lastUsed = Date()
        if let error, !error.isEmpty {
            accounts[i].lastError = Fmt.line(error, 180)
            accounts[i].lastErrorAt = Date()
        } else {
            accounts[i].lastError = ""
            accounts[i].lastErrorAt = nil
        }
        // Keep the sheet light: 120 days is more than the week view needs.
        if accounts[i].usage.count > 120 {
            let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? .distantPast
            let old = accounts[i].usage.keys.filter { WebAccount.day.date(from: $0).map { $0 < cutoff } ?? false }
            for k in old { accounts[i].usage[k] = nil }
        }
        save()
    }

    func markError(_ id: UUID, _ message: String) {
        record(id, prompt: 0, completion: 0, error: message)
    }

    func resetUsage(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].usage = [:]
        accounts[i].lastError = ""
        accounts[i].lastErrorAt = nil
        save()
    }

    /// Required cookie for a provider (what "signed in" means).
    nonisolated static func requiredCookie(_ provider: Provider) -> String {
        provider == .chatgpt ? "__Secure-next-auth.session-token" : "__Secure-1PSID"
    }

    nonisolated static func looksSignedIn(_ provider: Provider, _ cookies: [String: String]) -> Bool {
        let name = requiredCookie(provider)
        return cookies.keys.contains { ($0 == name || $0.hasPrefix(name + ".")) && !(cookies[$0] ?? "").isEmpty }
    }

    /// Parses a pasted cookie header, DevTools JSON dump, or `name=value` list.
    nonisolated static func parseCookies(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        let text = raw.replacingOccurrences(of: "Cookie:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in list {
                if let n = item["name"] as? String, let v = item["value"] as? String, !n.isEmpty { out[n] = v }
            }
        }
        let parts = text.split(whereSeparator: { $0 == ";" || $0 == "\n" })
        for part in parts {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let name = String(piece[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(piece[piece.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !value.isEmpty, name.range(of: #"^[A-Za-z0-9_\-\.]+$"#, options: .regularExpression) != nil {
                out[name] = value
            }
        }
        return out
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            accounts = state.accounts
            active = state.active
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        let state = State(accounts: accounts, active: active)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }

    private struct State: Codable {
        var accounts: [WebAccount] = []
        var active: [Provider: UUID] = [:]
    }

    private static func cookiesJSON(_ cookies: [String: String]) -> String? {
        guard !cookies.isEmpty, let data = try? JSONSerialization.data(withJSONObject: cookies) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A cookie jar for one account. The site's rotating Cloudflare and session cookies are merged back into the Keychain.
nonisolated final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [String: String]
    private let accountID: UUID

    init(accountID: UUID, cookies: [String: String]) {
        self.accountID = accountID
        self.cookies = cookies
    }

    var header: String {
        lock.lock(); defer { lock.unlock() }
        return cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return cookies.isEmpty
    }

    var snapshot: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return cookies
    }

    func merge(response: HTTPURLResponse, url: URL) {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let k = key as? String, k.lowercased() == "set-cookie", let v = value as? String else { continue }
            fields["Set-Cookie"] = v
        }
        guard let field = fields["Set-Cookie"] else { return }
        var changed = false
        for candidate in Self.splitSetCookie(field) {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": candidate], for: url) {
                changed = true
                if cookie.value.isEmpty { cookies[cookie.name] = nil } else { cookies[cookie.name] = cookie.value }
            }
        }
        if changed {
            let snapshot = cookies
            Task { @MainActor in WebAccounts.shared.updateCookies(accountID, snapshot) }
        }
    }

    /// Set-Cookie headers are comma-joined; Expires also has commas, so split only before `name=`.
    private static func splitSetCookie(_ raw: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j] == " " { j += 1 }
                var k = j
                while k < chars.count, chars[k] != "=", chars[k] != ";", chars[k] != "," { k += 1 }
                if k < chars.count, chars[k] == "=", j < k {
                    out.append(current); current = ""; i = j; continue
                }
            }
            current.append(c)
            i += 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func all(for provider: Provider, from store: WKWebsiteDataStore) async -> [String: String] {
        await withCheckedContinuation { cont in
            store.httpCookieStore.getAllCookies { list in
                var out: [String: String] = [:]
                for c in list {
                    let keep = provider == .chatgpt ? c.domain.contains("chatgpt.com") : c.domain.contains("google.com")
                    if keep, !c.value.isEmpty { out[c.name] = c.value }
                }
                cont.resume(returning: out)
            }
        }
    }
}

/// Checks a set of cookies against the site and describes the account, so every way of adding
/// one (sign-in window, Safari, pasted cookies, "Check sign-in") behaves the same.
nonisolated enum WebSignIn {
    struct Verified: Sendable {
        var accountID: UUID
        var email = ""
        var detail = ""
        var cookies: [String: String] = [:]
    }

    static func verify(_ provider: Provider, cookies: [String: String], accountID: UUID = UUID()) async throws -> Verified {
        guard WebAccounts.looksSignedIn(provider, cookies) else {
            throw BrainError(status: 401, code: "unauthorized", message: "Not signed in yet.")
        }
        var v = Verified(accountID: accountID)
        if provider == .chatgpt {
            let client = ChatGPTWebClient(accountID: accountID, cookies: cookies)
            let id = try await client.identity()
            v.email = id.email
            v.detail = [id.email, id.plan.isEmpty ? "" : "\(id.plan.capitalized) plan"].filter { !$0.isEmpty }.joined(separator: " · ")
            v.cookies = client.currentCookies
        } else {
            let client = GeminiWebClient(accountID: accountID, cookies: cookies)
            v.email = try await client.identity()
            v.detail = v.email.isEmpty ? "Google account" : v.email
            v.cookies = client.currentCookies
        }
        return v
    }

    /// Safari's session for this provider, but only if it belongs to the same person as `account`
    /// (Safari may be signed in to someone else). Used to revive an expired account quietly.
    static func safariSession(matching account: WebAccount) async -> Verified? {
        guard let safari = try? SafariCookies.cookies(for: account.provider),
              WebAccounts.looksSignedIn(account.provider, safari),
              let v = try? await verify(account.provider, cookies: safari, accountID: account.id) else { return nil }
        let want = account.email.lowercased()
        guard !want.isEmpty, v.email.lowercased() == want else { return nil }
        return v
    }

    /// One short line for an error from a sign-in check.
    static func message(_ error: Error) -> String {
        (error as? BrainError)?.message ?? error.localizedDescription
    }
}
