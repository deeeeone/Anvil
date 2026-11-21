import Foundation

/// Routes agent turns to the right provider: Experiential Labs, the Luna API, or the Gemini web proxy.
/// Turns that carry an image go to a model that can see (the vision model, or Gemini itself).
final class Brain {
    var model: String
    var visionModel: String
    var effort: String
    var visionEffort: String
    let experiential: OpenAIClient?
    let luna: OpenAIClient?
    let gemini: GeminiWebClient?
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
         experiential: OpenAIClient? = nil, luna: OpenAIClient? = nil, gemini: GeminiWebClient? = nil) {
        self.model = model
        self.visionModel = visionModel
        self.effort = effort
        self.visionEffort = visionEffort
        self.experiential = experiential
        self.luna = luna
        self.gemini = gemini
    }

    /// Test convenience (keeps the old shape).
    convenience init(client: OpenAIClient, model: String, visionModel: String, effort: String, visionEffort: String) {
        self.init(model: model, visionModel: visionModel, effort: effort, visionEffort: visionEffort, experiential: client)
    }

    static func fromSettings(model: String? = nil) throws -> Brain {
        let s = AppSettings.shared
        let m = model ?? s.model
        let p = Providers.provider(for: m)
        guard s.ready(p) else {
            throw BrainError(status: 0, code: "no_key", message: p == .gemini ? "Add the Gemini proxy key in Settings (or import it from Peep)." : "")
        }
        let exp = s.hasKey ? URL(string: s.baseURL).map { OpenAIClient(baseURL: $0, apiKey: s.apiKey) } : nil
        let luna = URL(string: s.lunaURL).map { OpenAIClient(baseURL: $0, apiKey: "") }
        let gem = s.geminiKey.isEmpty ? nil : URL(string: s.geminiURL).map { GeminiWebClient(baseURL: $0, apiKey: s.geminiKey) }
        // A vision model is only usable when its provider is set up.
        let vision = s.ready(Providers.provider(for: s.visionModel)) ? s.visionModel : ""
        return Brain(model: m, visionModel: vision, effort: s.effort, visionEffort: s.visionEffort, experiential: exp, luna: luna, gemini: gem)
    }

    /// Which model a history goes to, and whether to send its images.
    nonisolated static func route(_ history: [ChatMessage], model: String, vision: String) -> (model: String, images: Bool) {
        guard history.last?.hasImage ?? false else { return (model, false) }
        if Providers.seesImages(model) { return (model, true) }
        if !vision.isEmpty { return (vision, true) }
        return (model, false)
    }

    nonisolated static func retryable(_ e: BrainError) -> Bool {
        ["network", "upstream_error", "server_busy", "upstream_timeout", "bad_response", "not_ready", "upstream_blocked"].contains(e.code)
            || e.status == 503 || e.status == 429 || e.message.lowercased().contains("retry")
    }

    /// A Brain for a helper agent: same providers and usage accounting, its own Gemini session.
    func fork(model m: String? = nil) -> Brain {
        let b = Brain(model: m ?? model, visionModel: visionModel, effort: effort, visionEffort: visionEffort,
                      experiential: experiential, luna: luna, gemini: gemini)
        b.onUsage = onUsage
        b.override = override
        b.effort = "low"   // helpers only read and search
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
        let turnEffort = images ? visionEffort : (requestedEffort ?? effort)
        // Streaming has no built-in retry: retry transient failures here.
        var attempt = 0
        while true {
            do {
                return try await call(history, model: m, images: images, effort: turnEffort, stop: OpenAIClient.agentStops, agent: true, maxTokens: maxTokens)
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
        case .gemini:
            guard let gemini else { throw BrainError(status: 0, code: "no_key", message: "Add the Gemini proxy key in Settings.") }
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
                text = try await gemini.chatStream([message], model: m, sessionID: id, onText: stream, shouldStop: Self.replyComplete).text
            } else {
                text = try await gemini.chat([message], model: m, sessionID: agent ? id : nil)
            }
            if agent { geminiSession = (id, history.count + 1) }   // + the reply the agent appends
            record(nil, model: m, history: [message], reply: text, free: true)
            return text
        }
    }

    /// Collapses a multi-turn history into one user message (for a fresh Gemini session).
    nonisolated static func fold(_ history: [ChatMessage]) -> ChatMessage {
        guard history.count > 1 else { return history.last ?? .user("") }
        var s = history[0].text + "\n\nCONVERSATION SO FAR (your earlier replies and the app's observations)\n"
        let middle = Array(history.dropFirst().dropLast())
        for (i, m) in middle.enumerated() {
            let recent = i >= middle.count - 6
            let body = recent ? m.text : Fmt.clip(m.text, max: 1200)
            s += m.role == "assistant" ? "\n[your reply]\n\(body)\n" : "\n[app]\n\(body)\n"
        }
        let last = history[history.count - 1]
        s += "\n[app: latest]\n" + last.text
        let images = last.parts.compactMap { if case .image(let d, let mime) = $0 { return (d, mime) } else { return nil } }
        return .user(s, images: images)
    }

    private func record(_ usage: ChatUsage?, model: String, history: [ChatMessage], reply: String, free: Bool) {
        var u = usage ?? ChatUsage()
        if usage == nil {
            u.prompt = history.reduce(0) { $0 + $1.charCount } / 4
            u.completion = reply.count / 4
        }
        let cost: Double? = free ? 0 : (u.cost ?? ModelCatalog.shared.info(model)?.cost(prompt: u.prompt, completion: u.completion, cached: u.cached))
        onUsage?(u, model, cost)
    }
}
