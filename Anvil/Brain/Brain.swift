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

    func reply(_ history: [ChatMessage]) async throws -> String {
        let (m, images) = Self.route(history, model: model, vision: visionModel)
        if let override { return try await override(history, m) }
        return try await call(history, model: m, images: images, effort: images ? visionEffort : effort, stop: OpenAIClient.agentStops, agent: true)
    }

    /// A single side question (commit messages, summaries) at low effort.
    func oneShot(_ prompt: String, effort: String = "low") async throws -> String {
        let history = [ChatMessage.user(prompt)]
        if let override { return try await override(history, model) }
        return try await call(history, model: model, images: false, effort: effort, stop: nil, agent: false)
    }

    private func call(_ history: [ChatMessage], model m: String, images: Bool, effort e: String, stop: [String]?, agent: Bool) async throws -> String {
        switch Providers.provider(for: m) {
        case .experiential:
            guard let experiential else { throw BrainError(status: 0, code: "no_key", message: "") }
            let (text, usage) = try await experiential.chat(history, model: m, sendImages: images, effort: e.isEmpty ? nil : e, stop: stop)
            record(usage, model: m, history: history, reply: text, free: false)
            return text
        case .luna:
            guard let luna else { throw BrainError(status: 0, code: "network", message: "Set the Luna API URL in Settings.") }
            let (text, usage) = try await luna.chat(history, model: m, sendImages: images, effort: e.isEmpty ? nil : e, stop: stop)
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
            let text = try await gemini.chat([message], model: m, sessionID: agent ? id : nil)
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
