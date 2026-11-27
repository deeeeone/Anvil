import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ChatGPT's own web backend, implemented here instead of through a local proxy.
/// The account's cookies come from a real sign-in in the embedded browser (or a paste).
nonisolated final class ChatGPTWebClient: @unchecked Sendable {
    let accountID: UUID
    private let jar: CookieJar
    private let session: URLSession
    private let deviceID: String

    static let base = URL(string: "https://chatgpt.com")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"

    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private var sentinel: (token: String, proof: String)?
    private var dpl = ""
    private var scripts: [String] = []

    init(accountID: UUID, cookies: [String: String]) {
        self.accountID = accountID
        jar = CookieJar(accountID: accountID, cookies: cookies)
        deviceID = cookies["oai-did"] ?? UserDefaults.standard.string(forKey: "chatgptDevice.\(accountID.uuidString)") ?? {
            let id = UUID().uuidString.lowercased()
            UserDefaults.standard.set(id, forKey: "chatgptDevice.\(accountID.uuidString)")
            return id
        }()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 900
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: cfg)
    }

    // MARK: Identity

    struct Identity: Sendable {
        var email = ""
        var plan = ""
    }

    /// The cookie jar after any rotations (for saving a validated account).
    var currentCookies: [String: String] { jar.snapshot }

    /// Confirms the cookies are signed in and describes the account.
    func identity() async throws -> Identity {
        let data = try await authorizedGet("api/auth/session")
        let j = JSON.parse(String(decoding: data, as: UTF8.self))
        if let token = j?["accessToken"]?.string, !token.isEmpty {
            accessToken = token
            tokenExpiry = Date().addingTimeInterval(20 * 60)
        }
        var id = Identity()
        id.email = j?["user"]?["email"]?.string ?? ""
        id.plan = j?["user"]?["plan_type"]?.string ?? j?["plan_type"]?.string ?? j?["account"]?["plan_type"]?.string ?? ""
        guard !id.email.isEmpty || !(j?["accessToken"]?.string ?? "").isEmpty else {
            throw BrainError(status: 401, code: "unauthorized", message: "The cookies don't contain a signed-in ChatGPT session.")
        }
        if let token = j?["accessToken"]?.string, !token.isEmpty {
            do { try await verify(token) }
            catch {
                do {
                    let fresh = try await refreshedToken(reason: "token_revoked", failed: token)
                    try await verify(fresh)
                } catch {
                    throw BrainError(status: 401, code: "revoked", message: "ChatGPT revoked this session token. Sign in again, ideally fresh in Safari, then import it.")
                }
            }
        }
        return id
    }

    // MARK: Chat

    func chat(_ messages: [ChatMessage], model: String, onText: ((String) -> Void)?, shouldStop: ((String) -> Bool)?) async throws -> (text: String, conversationID: String) {
        var token = try await accessTokenValue()
        var sentinelToken: String
        var proof: String
        do {
            (sentinelToken, proof) = try await requirements(token)
        } catch let e as BrainError where e.code == "revoked" || e.code == "unauthorized" {
            accessToken = nil
            tokenExpiry = .distantPast
            self.sentinel = nil
            token = try await accessTokenValue()
            (sentinelToken, proof) = try await requirements(token)
        }
        return try await conversation(messages, model: model, token: token, sentinel: sentinelToken, proof: proof,
                                      onText: onText, shouldStop: shouldStop)
    }

    private func conversation(_ messages: [ChatMessage], model: String, token: String, sentinel: String, proof: String,
                              onText: ((String) -> Void)?, shouldStop: ((String) -> Bool)?) async throws -> (text: String, conversationID: String) {
        let slug = model.hasPrefix("chatgpt/") ? String(model.dropFirst("chatgpt/".count)) : model
        var list: [[String: Any]] = []
        for m in messages {
            list.append([
                "id": UUID().uuidString,
                "author": ["role": m.role == "assistant" ? "assistant" : m.role == "system" ? "system" : "user"],
                "create_time": Date().timeIntervalSince1970,
                "content": ["content_type": "text", "parts": [m.text]],
                "metadata": [
                    "developer_mode_connector_ids": [], "selected_connector_ids": [],
                    "selected_sync_knowledge_store_ids": [], "selected_sources": [],
                    "selected_github_repos": [], "selected_all_github_repos": false,
                    "serialization_metadata": ["custom_symbol_offsets": []],
                ],
            ])
        }
        var body: [String: Any] = [
            "action": "next",
            "messages": list,
            "parent_message_id": UUID().uuidString,
            "model": slug,
            "client_prepare_state": "success",
            "timezone_offset_min": -TimeZone.current.secondsFromGMT() / 60,
            "timezone": TimeZone.current.identifier,
            "conversation_mode": ["kind": "primary_assistant"],
            "enable_message_followups": true,
            "system_hints": [],
            "supports_buffering": true,
            "supported_encodings": ["v1"],
            "client_contextual_info": [
                "is_dark_mode": true, "time_since_loaded": Int.random(in: 500...5000),
                "page_height": 1129, "page_width": 382, "pixel_ratio": 2,
                "screen_height": 1440, "screen_width": 2560, "app_name": "chatgpt.com",
            ],
            "paragen_cot_summary_display_override": "allow",
            "force_parallel_switch": "auto",
            "history_and_training_disabled": true,
        ]
        if slug.contains("thinking") || slug.contains("pro") || slug.contains("cot") { body["thinking_effort"] = "standard" }

        var req = request("backend-api/conversation", method: "POST")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !sentinel.isEmpty { req.setValue(sentinel, forHTTPHeaderField: "Openai-Sentinel-Chat-Requirements-Token") }
        if !proof.isEmpty { req.setValue(proof, forHTTPHeaderField: "Openai-Sentinel-Proof-Token") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var text: String
        var convID: String
        do {
            (text, convID) = try await readStream(req, onText: onText, shouldStop: shouldStop)
        } catch let e as BrainError where e.code == "revoked" || e.code == "unauthorized" {
            accessToken = nil
            tokenExpiry = .distantPast
            self.sentinel = nil
            let fresh = try await accessTokenValue()
            let freshSentinel = try await self.requirements(fresh)
            req.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            if !freshSentinel.0.isEmpty { req.setValue(freshSentinel.0, forHTTPHeaderField: "Openai-Sentinel-Chat-Requirements-Token") }
            if !freshSentinel.1.isEmpty { req.setValue(freshSentinel.1, forHTTPHeaderField: "Openai-Sentinel-Proof-Token") }
            (text, convID) = try await readStream(req, onText: onText, shouldStop: shouldStop)
        }
        if text.isEmpty { throw BrainError(status: 200, code: "bad_response", message: "ChatGPT returned an empty reply.") }
        if !convID.isEmpty { Task { await self.cleanUp(convID, token: token) } }
        return (text, convID)
    }

    private func readStream(_ req: URLRequest, onText: ((String) -> Void)?, shouldStop: ((String) -> Bool)?) async throws -> (String, String) {
        var bytes: URLSession.AsyncBytes
        var resp: URLResponse
        do { (bytes, resp) = try await session.bytes(for: req) }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BrainError(status: 0, code: "network", message: error.localizedDescription)
        }
        let http = resp as? HTTPURLResponse
        if let http { jar.merge(response: http, url: Self.base) }
        guard let http, (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 6000 { break } }
            let status = http?.statusCode ?? 0
            let body = String(decoding: data, as: UTF8.self)
            if body.contains("token_revoked") || body.contains("token_invalidated") || body.contains("expired_session") {
                throw BrainError(status: status, code: "revoked", message: Fmt.line(body, 220))
            }
            throw Self.error(status: status, body: body)
        }

        var full = ""
        var conversationID = ""
        var lastPath = ""
        var assistant = false
        var lines = 0
        func emit(_ value: String) {
            guard assistant else { return }
            full += value
            onText?(full)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()   // the watchdog cancels a silent or runaway turn
            lines += 1
            if lines % 40 == 0, shouldStop?(full) == true { break }
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { continue }
            guard let parsed = JSON.parse(payload) else { continue }
            if let cid = parsed["conversation_id"]?.string, !cid.isEmpty { conversationID = cid }
            if let v = parsed["v"], let msg = v["message"], let role = msg["author"]?["role"]?.string {
                assistant = role == "assistant"
                if assistant, let part = msg["content"]?["parts"]?.array?.first?.string { full = part }
            }
            if parsed["o"]?.string == "append" {
                if let p = parsed["p"]?.string { lastPath = p }
                if lastPath == "/message/content/parts/0", let v = parsed["v"]?.string { emit(v) }
            } else if let ops = parsed["v"]?.array, parsed["p"] == nil, parsed["type"] == nil {
                // Patch batches arrive with a top-level "patch", and later deltas as a bare v array.
                for op in ops where op["o"]?.string == "append" && op["p"]?.string == "/message/content/parts/0" {
                    if let v = op["v"]?.string { emit(v) }
                }
            } else if parsed["v"]?.string != nil, parsed["o"] == nil, parsed["p"] == nil, parsed["type"] == nil {
                if lastPath == "/message/content/parts/0", let v = parsed["v"]?.string { emit(v) }
            }
            if parsed["v"] == nil, let msg = parsed["message"], msg["author"]?["role"]?.string == "assistant" {
                assistant = true
                if let part = msg["content"]?["parts"]?.array?.first?.string { full = part; onText?(full) }
            }
        }
        return (full, conversationID)
    }

    private func cleanUp(_ id: String, token: String) async {
        var req = request("backend-api/conversation/\(id)", method: "PATCH")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["is_archived": true])
        _ = try? await session.data(for: req)
        var del = request("backend-api/conversation/\(id)", method: "DELETE")
        del.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: del)
    }

    // MARK: Auth and sentinel

    private func accessTokenValue() async throws -> String {
        if let accessToken, Date() < tokenExpiry { return accessToken }
        let data = try await authorizedGet("api/auth/session")
        let j = JSON.parse(String(decoding: data, as: UTF8.self))
        guard var token = j?["accessToken"]?.string, !token.isEmpty else {
            throw BrainError(status: 401, code: "unauthorized", message: "ChatGPT sign-in expired. Add the account again.")
        }
        do { try await verify(token) }
        catch {
            token = try await refreshedToken(reason: "token_revoked", failed: token)
            try await verify(token)
        }
        accessToken = token
        tokenExpiry = Date().addingTimeInterval(20 * 60)
        return token
    }

    /// `/backend-api/me` with the token; a revoked/expired token is rejected here.
    private func verify(_ token: String) async throws {
        var req = request("backend-api/me")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(decoding: data, as: UTF8.self)
            let revoked = body.contains("token_revoked") || body.contains("token_invalidated") || body.contains("expired_session")
            throw BrainError(status: status, code: revoked ? "revoked" : "unauthorized", message: Fmt.line(body, 200))
        }
    }

    /// Asks the site for a new access token, the way its own session-recovery code does.
    private func refreshedToken(reason: String, failed: String) async throws -> String {
        var path = "api/auth/session?refresh=true&reason=\(reason)&method=POST&path=%2Fbackend-api%2Fconversation"
        var comps = URLComponents(url: Self.base.appendingPathComponent("api/auth/session"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "refresh", value: "true"), URLQueryItem(name: "reason", value: reason),
            URLQueryItem(name: "method", value: "POST"), URLQueryItem(name: "path", value: "/backend-api/conversation"),
        ]
        guard let url = comps.url else { throw BrainError(status: 0, code: "network", message: "Bad session URL") }
        path = url.absoluteString
        var req = request("api/auth/session")
        req.url = url
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("/api/auth/session", forHTTPHeaderField: "X-OpenAI-Target-Path")
        req.setValue("/api/auth/session", forHTTPHeaderField: "X-OpenAI-Target-Route")
        if let iat = Self.issuedAt(failed) { req.setValue(String(iat), forHTTPHeaderField: "X-OpenAI-Failed-Access-Token-Iat") }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let token = JSON.parse(String(decoding: data, as: UTF8.self))?["accessToken"]?.string, !token.isEmpty else {
            throw BrainError(status: 401, code: "unauthorized", message: "The ChatGPT session is revoked. Add the account again.")
        }
        accessToken = token
        tokenExpiry = Date().addingTimeInterval(20 * 60)
        return token
    }

    private static func issuedAt(_ jwt: String) -> Int? {
        let pieces = jwt.split(separator: ".")
        guard pieces.count > 1 else { return nil }
        var body = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while body.count % 4 != 0 { body += "=" }
        guard let data = Data(base64Encoded: body),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["iat"] as? Int
    }

    private func authorizedGet(_ path: String, retry: Bool = true) async throws -> Data {
        let (data, resp) = try await raw(path)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403, retry {
            _ = try? await fetchPage(force: true)
            return try await authorizedGet(path, retry: false)
        }
        guard (200..<300).contains(status) else { throw Self.error(status: status, body: String(decoding: data, as: UTF8.self)) }
        return data
    }

    private func raw(_ path: String) async throws -> (Data, URLResponse) {
        var req = request(path)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do { let r = try await session.data(for: req); return (r.0, r.1) }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BrainError(status: 0, code: "network", message: error.localizedDescription)
        }
    }

    /// Visits the homepage to pick up fresh Cloudflare cookies, the build label and script names.
    @discardableResult
    func fetchPage(force: Bool) async throws -> Data {
        var req = request("")
        req.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse { jar.merge(response: http, url: Self.base) }
        let html = String(decoding: data, as: UTF8.self)
        let found = Self.matches(#"src="(https://cdn\.oaistatic\.com/[^"]+\.js)""#, in: html)
        if !found.isEmpty { scripts = found }
        if dpl.isEmpty {
            dpl = Self.matches(#"data-build="([^"]+)""#, in: html).first ?? ""
            if dpl.isEmpty, let script = found.first {
                dpl = Self.matches(#"(?:c/|_next/static/)([a-zA-Z0-9_-]+)/"#, in: script).first ?? ""
            }
            if dpl.isEmpty { dpl = "dpl-" + UUID().uuidString.prefix(8).lowercased() }
        }
        return data
    }

    private func requirements(_ token: String, retry: Bool = true) async throws -> (String, String) {
        if let sentinel { return (sentinel.token, sentinel.proof) }
        try await fetchPage(force: dpl.isEmpty)
        var req = request("backend-api/sentinel/chat-requirements", method: "POST")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["p": "gAAAAAC" + base64Config()])
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse { jar.merge(response: http, url: Self.base) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403, retry {
            _ = try? await fetchPage(force: true)
            return try await requirements(token, retry: false)
        }
        guard status == 200 else { throw Self.error(status: status, body: String(decoding: data, as: UTF8.self)) }
        let j = JSON.parse(String(decoding: data, as: UTF8.self))
        let tokenValue = j?["token"]?.string ?? ""
        var proof = ""
        if let pow = j?["proofofwork"], pow["required"]?.bool == true,
           let seed = pow["seed"]?.string, let difficulty = pow["difficulty"]?.string {
            proof = Self.solve(seed: seed, difficulty: difficulty, dpl: dpl, scripts: scripts)
        }
        sentinel = (tokenValue, proof)
        return (tokenValue, proof)
    }

    // MARK: Proof of work

    private func base64Config() -> String {
        Self.base64Config(dpl: dpl, scripts: scripts)
    }

    private static func base64Config(dpl: String, scripts: [String]) -> String {
        let config = config(dpl: dpl, scripts: scripts, nonce: 0)
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return "" }
        return data.base64EncodedString()
    }

    private static let navigatorKeys = ["hardwareConcurrency-16", "vendor-Google Inc.", "appVersion-5.0",
                                        "platform-Linux x86_64", "language-en-US", "onLine-true",
                                        "cookieEnabled-true", "deviceMemory-8", "maxTouchPoints-0"]
    private static let documentKeys = ["_reactListeningo743lnnpvdg", "location"]
    private static let windowKeys = ["Object", "Function", "Array", "Number", "parseFloat", "parseInt",
                                     "Infinity", "NaN", "undefined", "Boolean", "String", "Symbol", "Date",
                                     "Promise", "RegExp", "Error", "JSON", "Math", "Intl", "ArrayBuffer",
                                     "Map", "Set", "WeakMap", "WeakSet", "Proxy", "Reflect", "console",
                                     "fetch", "crypto", "performance", "localStorage", "sessionStorage",
                                     "navigator", "location", "history", "screen", "document", "window",
                                     "self", "__NEXT_DATA__", "__next_f"]
    private static let cores = [8, 12, 16, 24, 32]
    private static let screenSums = [3000, 4000, 3120, 4160]

    private static func config(dpl: String, scripts: [String], nonce: Int) -> [Any] {
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT-0500 (Eastern Standard Time)'"
        let start = Date().timeIntervalSince1970 * 1000 - (ProcessInfo.processInfo.systemUptime * 1000)
        return [
            screenSums.randomElement()!, f.string(from: now), 4294705152, nonce,
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            scripts.randomElement() ?? "", dpl, "en-US", "en-US,es-US,en,es", nonce >> 1,
            navigatorKeys.randomElement()!, documentKeys.randomElement()!, windowKeys.randomElement()!,
            ProcessInfo.processInfo.systemUptime * 1000, UUID().uuidString, "", cores.randomElement()!, start,
        ]
    }

    static func solve(seed: String, difficulty: String, dpl: String, scripts: [String]) -> String {
        let target = [UInt8](hex: difficulty)
        guard !target.isEmpty else { return "" }
        let seedData = Data(seed.utf8)
        for nonce in 0..<500_000 {
            let config = config(dpl: dpl, scripts: scripts, nonce: nonce)
            guard let json = try? JSONSerialization.data(withJSONObject: config) else { continue }
            let b64 = json.base64EncodedString()
            let digest = SHA3.hash(seedData + Data(b64.utf8))
            if digest.prefix(target.count).lexicographicallyPrecedes(target) || Array(digest.prefix(target.count)) == target {
                return "gAAAAAB" + b64
            }
        }
        return ""
    }

    // MARK: Plumbing

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(jar.header, forHTTPHeaderField: "Cookie")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue(deviceID, forHTTPHeaderField: "Oai-Device-Id")
        req.setValue("en-US", forHTTPHeaderField: "Oai-Language")
        return req
    }

    private static func error(status: Int, body: String) -> BrainError {
        let clean = Fmt.line(body, 300)
        let code: String
        if status == 401 || status == 403 { code = "unauthorized" }
        else if status == 429 || clean.contains("usage_limit") || clean.lowercased().contains("rate limit") { code = "usage_limit" }
        else if status == 413 || clean.contains("message_length") { code = "too_long" }
        else { code = "upstream_error" }
        return BrainError(status: status, code: code, message: clean)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            guard $0.numberOfRanges > 1, let r = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }
}

private extension Array where Element == UInt8 {
    init(hex: String) {
        self.init()
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            if let b = UInt8(hex[i..<j], radix: 16) { append(b) }
            i = j
        }
    }
}
