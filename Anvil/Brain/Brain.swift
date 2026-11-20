import Foundation

/// Routes agent turns to the provider: the daily-driver model for text, the vision model for turns with images.
final class Brain {
    let client: OpenAIClient
    var model: String
    var visionModel: String
    var effort: String
    var visionEffort: String
    /// Called after every call with the usage and the cost (provider figure, else catalog estimate).
    var onUsage: ((ChatUsage, String, Double?) -> Void)?
    /// Test hook: replaces the network call.
    var override: (([ChatMessage], String) async throws -> String)?

    init(client: OpenAIClient, model: String, visionModel: String, effort: String, visionEffort: String) {
        self.client = client
        self.model = model
        self.visionModel = visionModel
        self.effort = effort
        self.visionEffort = visionEffort
    }

    static func fromSettings(model: String? = nil) throws -> Brain {
        let s = AppSettings.shared
        guard let url = URL(string: s.baseURL) else { throw BrainError(status: 0, code: "network", message: "bad base URL") }
        guard s.hasKey else { throw BrainError(status: 0, code: "no_key", message: "") }
        return Brain(client: OpenAIClient(baseURL: url, apiKey: s.apiKey), model: model ?? s.model,
                     visionModel: s.visionModel, effort: s.effort, visionEffort: s.visionEffort)
    }

    /// Which model a history goes to: the vision model only when the newest turn carries an image.
    nonisolated static func route(_ history: [ChatMessage], model: String, vision: String) -> (model: String, images: Bool) {
        let hasImage = history.last?.hasImage ?? false
        if hasImage && !vision.isEmpty { return (vision, true) }
        return (model, false)
    }

    func reply(_ history: [ChatMessage]) async throws -> String {
        let (m, images) = Self.route(history, model: model, vision: visionModel)
        if let override { return try await override(history, m) }
        let e = images ? visionEffort : effort
        let (text, usage) = try await client.chat(history, model: m, sendImages: images, effort: e.isEmpty ? nil : e, stop: OpenAIClient.agentStops)
        record(usage, model: m, history: history, reply: text)
        return text
    }

    /// A single side question (commit messages, summaries) on the main model at low effort.
    func oneShot(_ prompt: String, effort: String = "low") async throws -> String {
        let history = [ChatMessage.user(prompt)]
        if let override { return try await override(history, model) }
        let (text, usage) = try await client.chat(history, model: model, effort: effort)
        record(usage, model: model, history: history, reply: text)
        return text
    }

    private func record(_ usage: ChatUsage?, model: String, history: [ChatMessage], reply: String) {
        var u = usage ?? ChatUsage()
        if usage == nil {
            u.prompt = history.reduce(0) { $0 + $1.charCount } / 4
            u.completion = reply.count / 4
        }
        let cost = u.cost ?? ModelCatalog.shared.info(model)?.cost(prompt: u.prompt, completion: u.completion, cached: u.cached)
        onUsage?(u, model, cost)
    }
}
