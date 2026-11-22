import Foundation

/// Routes agent turns to the right provider: Experiential Labs, the Luna API, or the Gemini web proxy.
/// Turns that carry an image go to a model that can see (the vision model, or Gemini itself).
final class Brain {
    var model: String
    var visionModel: String
    var effort: String
    var visionEffort: String
    /// Set when a turn's reasoning ran away (see thinking_too_long): the rest of the request reasons at most this much.
    var effortCap: String?
    let experiential: OpenAIClient?
    let luna: OpenAIClient?
    let geminiProxy: GeminiProxyClient?
    let chatgptProxy: OpenAIClient?
    /// Called after every call with the usage and the cost (provider figure, else catalog estimate; free providers cost 0).
    var onUsage: ((ChatUsage, String, Double?) -> Void)?
    /// Test hook: replaces the network call.
    var override: (([ChatMessage], String) async throws -> String)?
    /// Live text while a reply streams in (nil = don't stream).
    var onStream: ((String) -> Void)?
    /// Why the last agent reply ended ("stop", "length"...), when the provider says.
    private(set) var lastFinishReason: String?

    /// The Gemini proxy keeps history server-side: the session id and how many messages it already holds.
    private var geminiSession: (id: String, seen: Int)?

    init(model: String, visionModel: String, effort: String, visionEffort: String,
         experiential: OpenAIClient? = nil, luna: OpenAIClient? = nil, gemini: GeminiProxyClient? = nil, chatgpt: OpenAIClient? = nil) {
        self.model = model
        self.visionModel = visionModel
        self.effort = effort
        self.visionEffort = visionEffort
        self.experiential = experiential
        self.luna = luna
        self.geminiProxy = gemini
        self.chatgptProxy = chatgpt
    }

    /// Test convenience (keeps the old shape).
    convenience init(client: OpenAIClient, model: String, visionModel: String, effort: String, visionEffort: String) {
        self.init(model: model, visionModel: visionModel, effort: effort, visionEffort: visionEffort, experiential: client)
    }

    static func fromSettings(model: String? = nil) throws -> Brain {
        let s = AppSettings.shared
        let m = model ?? s.model
        if let (plugin, _) = ProviderPlugins.shared.route(m), !ProviderPlugins.shared.isReady(plugin.id) {
            throw BrainError(status: 0, code: "no_key", message: "Set up \(plugin.spec.name) first: Settings → Provider → \(plugin.spec.auth.type == .web ? "Sign in" : "API key").")
        }
        let p = Providers.provider(for: m)
        guard ProviderPlugins.shared.route(m) != nil || s.ready(p) else {
            throw BrainError(status: 0, code: "no_key", message: p == .gemini ? "Sign in to Gemini first: pick a Gemini model from the model menu, or open Settings → Provider." : p == .chatgpt ? "Sign in to ChatGPT first: pick a ChatGPT model from the model menu, or open Settings → Provider." : "")
        }
        let exp = s.hasKey ? URL(string: s.baseURL).map { OpenAIClient(baseURL: $0, apiKey: s.apiKey) } : nil
        let luna = URL(string: s.lunaURL).map { OpenAIClient(baseURL: $0, apiKey: "") }
        let gem = s.geminiKey.isEmpty ? nil : URL(string: s.geminiURL).map { GeminiProxyClient(baseURL: $0, apiKey: s.geminiKey) }
        let cg = s.chatgptProxyConfigured ? URL(string: s.chatgptURL).map { OpenAIClient(baseURL: $0, apiKey: "") } : nil
        // A vision model is only usable when its provider is set up.
        let vision = s.ready(model: s.visionModel) ? s.visionModel : ""
        return Brain(model: m, visionModel: vision, effort: s.effort, visionEffort: s.visionEffort, experiential: exp, luna: luna, gemini: gem, chatgpt: cg)
    }

    /// Which model a history goes to, and whether to send its images.
    static func route(_ history: [ChatMessage], model: String, vision: String) -> (model: String, images: Bool) {
        guard history.last?.hasImage ?? false else { return (model, false) }
        if let info = ProviderPlugins.shared.modelInfo(model) { if info.vision == true { return (model, true) } }
        else if ProviderPlugins.shared.route(model) == nil, Providers.seesImages(model) { return (model, true) }
        if !vision.isEmpty { return (vision, true) }
        return (model, false)
    }

    nonisolated static func capped(_ effort: String, by cap: String?) -> String {
        let order = ["low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 4]
        guard let cap, let c = order[cap.lowercased()], let e = order[effort.lowercased()], e > c else { return effort }
        return cap
    }

    /// One notch less reasoning (nil once there's nothing lower).
    nonisolated static func lowerEffort(_ e: String) -> String? {
        switch e.lowercased() { case "max", "xhigh": return "high"; case "high": return "medium"; case "medium": return "low"; default: return nil }
    }

    nonisolated static func retryable(_ e: BrainError) -> Bool {
        ["network", "upstream_error", "server_busy", "upstream_timeout", "bad_response", "not_ready", "upstream_blocked"].contains(e.code)
            || e.status == 503 || e.status == 429 || e.message.lowercased().contains("retry")
    }

    /// A Brain for a helper agent: same providers and usage accounting, its own Gemini session.
    func fork(model m: String? = nil) -> Brain {
        let b = Brain(model: m ?? model, visionModel: visionModel, effort: effort, visionEffort: visionEffort,
                      experiential: experiential, luna: luna, gemini: geminiProxy, chatgpt: chatgptProxy)
        b.onUsage = onUsage
        b.override = override
        b.effort = "low"   // helpers only read and search
        b.effortCap = effortCap
        return b
    }

    /// The reply is finished once its first JSON block closes: anything after it is the model running ahead.
    nonisolated static func replyComplete(_ text: String) -> Bool {
        guard let open = text.range(of: "```json") ?? text.range(of: "```JSON") else { return false }
        let rest = text[open.upperBound...]
        guard let close = rest.range(of: "\n```") else { return false }
        let body = rest[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.hasPrefix("{") && ActionParser.parseLenient(String(body), repair: false) != nil
    }

    /// One agent turn. `model` overrides the session model for this turn (escalation, exploration routing).
    func reply(_ history: [ChatMessage], model requested: String? = nil, effort requestedEffort: String? = nil, maxTokens: Int? = nil) async throws -> String {
        let (m, images) = Self.route(history, model: requested ?? model, vision: visionModel)
        lastFinishReason = nil
        if let override { return try await override(history, m) }
        var turnEffort = Self.capped(images ? visionEffort : (requestedEffort ?? effort), by: effortCap)
        // Streaming has no built-in retry: retry transient failures here.
        var attempt = 0
        while true {
            do {
                return try await call(history, model: m, images: images, effort: turnEffort, stop: OpenAIClient.agentStops, agent: true, maxTokens: maxTokens)
            } catch let e as BrainError where e.code == "thinking_too_long" && Self.lowerEffort(turnEffort) != nil {
                // Runaway reasoning: redo this turn with less of it instead of burning the whole task budget.
                turnEffort = Self.lowerEffort(turnEffort)!
                effortCap = turnEffort
            } catch let e as BrainError where Self.retryable(e) && attempt < (e.code == "server_busy" ? 5 : 2) {
                // Rate limits and "not ready, retry shortly" get a real backoff (about 45 s in total); other blips a short one.
                attempt += 1
                let wait = e.retryAfter ?? (e.code == "server_busy" ? 3 * pow(2, Double(attempt - 1)) : Double(2 * attempt))
                try await Task.sleep(for: .seconds(min(20, wait)))
            }
        }
    }

    /// A single side question (commit messages, summaries) at low effort.
    func oneShot(_ prompt: String, effort: String = "low") async throws -> String {
        let history = [ChatMessage.user(prompt)]
        if let override { return try await override(history, model) }
        return try await call(history, model: model, images: false, effort: effort, stop: nil, agent: false, maxTokens: nil)
    }

    /// Sends a history with a 1-token reply so the provider caches its prefix (prompt caching is automatic on
    /// Experiential Labs). The real request that follows reuses it. Errors are ignored: this is only a speed-up.
    func warm(_ history: [ChatMessage]) async {
        guard override == nil, Providers.provider(for: model) == .experiential, let experiential else { return }
        if let (_, usage) = try? await experiential.chat(history, model: model, effort: "low", maxTokens: 1, attempts: 1) {
            record(usage, model: model, history: history, reply: "", free: false)
        }
    }

    private func call(_ history: [ChatMessage], model m: String, images: Bool, effort e: String, stop: [String]?, agent: Bool, maxTokens: Int?) async throws -> String {
        let stream = agent ? onStream : nil
        if let (plugin, name) = ProviderPlugins.shared.route(m) {
            // A provider plugin: its spec says what it supports; ignored stop sequences mean ending the stream ourselves.
            let client = ProviderClient(plugin)
            let stopEarly: (String) -> Bool = plugin.spec.honorsStop ? { _ in false } : { Self.replyComplete($0) }
            let (text, usage) = try await client.chat(history, model: name, images: images, effort: e.isEmpty ? nil : e, stop: stop,
                                                      maxTokens: maxTokens, onText: stream, shouldStop: stopEarly)
            if agent { lastFinishReason = usage?.finishReason }
            record(usage, model: m, history: history, reply: text, free: plugin.spec.free ?? false)
            return text
        }
        switch Providers.provider(for: m) {
        case .experiential:
            guard let experiential else { throw BrainError(status: 0, code: "no_key", message: "") }
            let text: String, usage: ChatUsage?
            if let stream {
                // Runs to the end (stop sequences end it) so the provider's exact usage and cost arrive.
                (text, usage, _) = try await experiential.chatStream(history, model: m, sendImages: images, effort: e.isEmpty ? nil : e, stop: stop,
                                                                     maxTokens: maxTokens, onText: stream, shouldStop: { _ in false })
            } else {
                (text, usage) = try await experiential.chat(history, model: m, sendImages: images, effort: e.isEmpty ? nil : e, stop: stop, maxTokens: maxTokens)
            }
            if agent { lastFinishReason = usage?.finishReason }
            record(usage, model: m, history: history, reply: text, free: false)
            return text
        case .luna:
            guard let luna else { throw BrainError(status: 0, code: "network", message: "Set the Luna API URL in Settings.") }
            let text: String, usage: ChatUsage?
            if let stream {
                // Luna ignores stop sequences: end the stream as soon as the JSON block is complete.
                (text, usage, _) = try await luna.chatStream(history, model: m, sendImages: images, effort: e.isEmpty ? nil : e, stop: stop,
                                                             maxTokens: maxTokens, onText: stream, shouldStop: Self.replyComplete)
            } else {
                (text, usage) = try await luna.chat(history, model: m, sendImages: images, effort: e.isEmpty ? nil : e, stop: stop, maxTokens: maxTokens)
            }
            if agent { lastFinishReason = usage?.finishReason }
            record(usage, model: m, history: history, reply: text, free: true)
            return text
        case .chatgpt:
            let accounts = WebAccounts.shared.candidates(for: .chatgpt)
            if !accounts.isEmpty {
                do {
                    let text = try await webChatGPT(history, model: m, stream: stream)
                    if agent { lastFinishReason = nil }
                    record(nil, model: m, history: history, reply: text, free: true)
                    return text
                } catch {
                    if chatgptProxy == nil { throw error }
                }
            }
            guard let chatgptProxy else { throw BrainError(status: 0, code: "network", message: "Add a ChatGPT account in Settings, or set the proxy URL.") }
            if let problem = await ChatGPTProxy.shared.ensureRunning() { throw BrainError(status: 0, code: "no_key", message: problem) }
            let text: String, usage: ChatUsage?
            do {
                if let stream {
                    // Like Luna: no stop-sequence support, so end the stream once the JSON block is complete.
                    (text, usage, _) = try await chatgptProxy.chatStream(history, model: m, sendImages: false, effort: nil, stop: nil,
                                                                         maxTokens: nil, onText: stream, shouldStop: Self.replyComplete)
                } else {
                    (text, usage) = try await chatgptProxy.chat(history, model: m, sendImages: false, stop: nil)
                }
            } catch let e as BrainError where e.status == 413 || e.message.contains("message_length") {
                throw BrainError(status: 413, code: "too_long", message: "ChatGPT's web app rejects messages this long. Use /compact, or a different model for big sessions.")
            }
            if agent { lastFinishReason = usage?.finishReason }
            record(usage, model: m, history: history, reply: text, free: true)
            return text
        case .gemini:
            let accounts = WebAccounts.shared.candidates(for: .gemini)
            if !accounts.isEmpty {
                do {
                    // The whole conversation goes to Gemini's web app as one message. When it refuses (its canned
                    // "something went wrong"), send a much tighter version once before giving up.
                    var message = Self.fold(history)
                    var text: String
                    do {
                        text = try await webGemini(message.text, images: Self.images(message), model: m, stream: stream)
                    } catch let e as BrainError where e.code == "gemini_error" {
                        message = Self.fold(history, recent: 3, olderClip: 300, recentClip: 4000)
                        do {
                            text = try await webGemini(message.text, images: Self.images(message), model: m, stream: stream)
                        } catch let again as BrainError where again.code == "gemini_error" {
                            throw BrainError(status: 413, code: "too_long", message: "Gemini's web app keeps failing on this conversation; it's too long for it. Run /compact, or switch to another model for this session.")
                        }
                    }
                    if agent { lastFinishReason = nil }
                    record(nil, model: m, history: [message], reply: text, free: true)
                    return text
                } catch {
                    if geminiProxy == nil { throw error }
                }
            }
            guard let geminiProxy else { throw BrainError(status: 0, code: "no_key", message: "Add a Gemini account in Settings, or a proxy key.") }
            // Reuse the server-side session when it already holds everything but the newest turn; otherwise fold.
            let message: ChatMessage
            let id: String
            if agent, let g = geminiSession, g.seen == history.count - 1 {
                message = history[history.count - 1]
                id = g.id
            } else {
                message = Self.fold(history)
                id = "anvil-\(UUID().uuidString.prefix(12))"
            }
            let text: String
            if let stream {
                text = try await geminiProxy.chatStream([message], model: m, sessionID: id, onText: stream, shouldStop: Self.replyComplete).text
            } else {
                text = try await geminiProxy.chat([message], model: m, sessionID: agent ? id : nil)
            }
            if agent { geminiSession = (id, history.count + 1) }   // + the reply the agent appends
            record(nil, model: m, history: [message], reply: text, free: true)
            return text
        }
    }

    /// Collapses a multi-turn history into one user message (for a fresh Gemini session).
    nonisolated static func images(_ m: ChatMessage) -> [(Data, String)] {
        m.parts.compactMap { if case .image(let d, let mime) = $0 { return (d, mime) } else { return nil } }
    }

    /// `recent` turns are kept in full (clipped to `recentClip`), older ones to `olderClip` characters.
    nonisolated static func fold(_ history: [ChatMessage], recent keep: Int = 6, olderClip: Int = 1200, recentClip: Int? = nil) -> ChatMessage {
        guard history.count > 1 else { return history.last ?? .user("") }
        var s = history[0].text + "\n\nCONVERSATION SO FAR (your earlier replies and the app's observations)\n"
        let middle = Array(history.dropFirst().dropLast())
        for (i, m) in middle.enumerated() {
            let recent = i >= middle.count - keep
            let body = recent ? (recentClip.map { Fmt.clip(m.text, max: $0) } ?? m.text) : Fmt.clip(m.text, max: olderClip)
            s += m.role == "assistant" ? "\n[your reply]\n\(body)\n" : "\n[app]\n\(body)\n"
        }
        let last = history[history.count - 1]
        s += "\n[app: latest]\n" + last.text
        let images = last.parts.compactMap { if case .image(let d, let mime) = $0 { return (d, mime) } else { return nil } }
        return .user(s, images: images)
    }

    /// Errors that mean "this account can't answer right now": try the next one.
    private static let fallThrough: Set<String> = ["revoked", "unauthorized", "network", "upstream_error", "upstream_timeout", "server_busy", "bad_response"]

    /// Tries the signed-in ChatGPT accounts, active first. A dead session or a rate limit moves to the next.
    /// An expired session is revived from Safari when Safari is signed in as the same person.
    private func webChatGPT(_ history: [ChatMessage], model m: String, stream: ((String) -> Void)?) async throws -> String {
        let store = WebAccounts.shared
        let stop: ((String) -> Bool)? = stream == nil ? nil : { Self.replyComplete($0) }
        var last: BrainError?
        for account in store.candidates(for: .chatgpt) {
            do {
                let client = ChatGPTWebClient(accountID: account.id, cookies: store.cookies(account.id))
                let reply = try await client.chat(history, model: m, onText: stream, shouldStop: stop).text
                store.record(account.id, prompt: Self.estimate(history), completion: reply.count / 4)
                return reply
            } catch let e as BrainError {
                if e.code == "too_long" {
                    throw BrainError(status: 413, code: "too_long", message: "ChatGPT's web app rejects messages this long. Use /compact, or a different model for big sessions.")
                }
                if e.code == "revoked" || e.code == "unauthorized", let fresh = await WebSignIn.safariSession(matching: account),
                   let reply = try? await ChatGPTWebClient(accountID: account.id, cookies: fresh.cookies).chat(history, model: m, onText: stream, shouldStop: stop).text {
                    store.save(fresh, provider: .chatgpt, replacing: account.id)
                    store.record(account.id, prompt: Self.estimate(history), completion: reply.count / 4)
                    return reply
                }
                let shown = e.code == "revoked" || e.code == "unauthorized"
                    ? BrainError(status: 401, code: e.code, message: "\(account.label) is signed out of ChatGPT. Open Settings → Provider and click Sign in again.")
                    : e
                store.markError(account.id, shown.message)
                last = shown
                guard Self.fallThrough.contains(e.code) else { throw e }
            }
        }
        throw last ?? BrainError(status: 0, code: "no_key", message: "No ChatGPT account is usable. Add one in Settings → Provider.")
    }

    private func webGemini(_ prompt: String, images: [(Data, String)], model m: String, stream: ((String) -> Void)?) async throws -> String {
        let store = WebAccounts.shared
        let stop: ((String) -> Bool)? = stream == nil ? nil : { Self.replyComplete($0) }
        var last: BrainError?
        for account in store.candidates(for: .gemini) {
            do {
                let client = GeminiWebClient(accountID: account.id, cookies: store.cookies(account.id))
                let reply = try await client.chat(prompt, images: images, model: m, onText: stream, shouldStop: stop)
                store.record(account.id, prompt: prompt.count / 4, completion: reply.count / 4)
                return reply
            } catch let e as BrainError {
                if e.code == "unauthorized", let fresh = await WebSignIn.safariSession(matching: account),
                   let reply = try? await GeminiWebClient(accountID: account.id, cookies: fresh.cookies).chat(prompt, images: images, model: m, onText: stream, shouldStop: stop) {
                    store.save(fresh, provider: .gemini, replacing: account.id)
                    store.record(account.id, prompt: prompt.count / 4, completion: reply.count / 4)
                    return reply
                }
                let shown = e.code == "unauthorized"
                    ? BrainError(status: 401, code: e.code, message: "\(account.label) is signed out of Gemini. Open Settings → Provider and click Sign in again.")
                    : e
                store.markError(account.id, shown.message)
                last = shown
                guard Self.fallThrough.contains(e.code) else { throw e }
            }
        }
        throw last ?? BrainError(status: 0, code: "no_key", message: "No Gemini account is usable. Add one in Settings → Provider.")
    }

    private static func estimate(_ history: [ChatMessage]) -> Int {
        history.reduce(0) { $0 + $1.charCount } / 4
    }

    private func record(_ usage: ChatUsage?, model: String, history: [ChatMessage], reply: String, free: Bool) {
        var u = usage ?? ChatUsage()
        let chars = history.reduce(0) { $0 + $1.charCount }
        if usage == nil {
            u.prompt = TokenCalibrator.shared.tokens(chars: chars, model: model)
            u.completion = Int((Double(reply.count) / TokenCalibrator.shared.ratio(for: model)).rounded())
        } else {
            // The provider counted this prompt: learn what a character of this conversation is worth for this model.
            TokenCalibrator.shared.learn(model: model, chars: chars, tokens: u.prompt)
        }
        var cost: Double? = free ? 0 : (u.cost ?? ModelCatalog.shared.info(model)?.cost(prompt: u.prompt, completion: u.completion, cached: u.cached))
        if !free, u.cost == nil, let m = ProviderPlugins.shared.modelInfo(model), m.input != nil || m.output != nil {
            cost = (Double(u.prompt) * (m.input ?? 0) + Double(u.completion) * (m.output ?? 0)) / 1_000_000
        }
        onUsage?(u, model, cost)
    }
}
