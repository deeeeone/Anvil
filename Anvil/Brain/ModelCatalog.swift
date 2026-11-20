import Foundation
import Observation

/// One model the provider offers, with what we need to pick and price it.
nonisolated struct ModelInfo: Identifiable, Hashable, Sendable {
    var id: String
    var contextTokens: Int?
    var maxOutputTokens: Int?
    var inputPerMillion: Double?
    var outputPerMillion: Double?
    var cachedInputPerMillion: Double?
    var reasoning = false
    var efforts: [String] = []
    var vision = false
    var chat = true

    var priceLabel: String {
        guard let i = inputPerMillion, let o = outputPerMillion else { return "price unknown" }
        return "$\(Self.money(i)) in, $\(Self.money(o)) out per M"
    }
    var contextLabel: String {
        guard let c = contextTokens else { return "" }
        return c >= 1_000_000 ? "\(c / 1_000_000)M ctx" : "\(c / 1000)k ctx"
    }
    static func money(_ v: Double) -> String { v >= 10 ? String(format: "%.0f", v) : v >= 1 ? String(format: "%.2f", v) : String(format: "%.3f", v) }

    /// Estimated cost of one call.
    func cost(prompt: Int, completion: Int, cached: Int = 0) -> Double? {
        guard let i = inputPerMillion, let o = outputPerMillion else { return nil }
        let fresh = max(0, prompt - cached)
        return (Double(fresh) * i + Double(cached) * (cachedInputPerMillion ?? i) + Double(completion) * o) / 1_000_000
    }

    static func parse(_ j: JSON) -> ModelInfo? {
        guard let id = j["id"]?.string else { return nil }
        var m = ModelInfo(id: id)
        m.contextTokens = j["context_window_tokens"]?.int ?? j["context_length"]?.int
        m.maxOutputTokens = j["maximum_output_tokens"]?.int
        let p = j["pricing"]
        func nano(_ k: String) -> Double? { p?[k]?.double.map { $0 / 1_000_000_000 } }
        m.inputPerMillion = nano("input_nano_usd_per_million_tokens") ?? j["input_cost_per_million_tokens_usd"]?.double
        m.outputPerMillion = nano("output_nano_usd_per_million_tokens") ?? j["output_cost_per_million_tokens_usd"]?.double
        m.cachedInputPerMillion = nano("cached_input_nano_usd_per_million_tokens") ?? j["cached_input_cost_per_million_tokens_usd"]?.double
        m.reasoning = j["supports_reasoning"]?.bool ?? false
        m.efforts = j["supported_reasoning_efforts"]?.array?.compactMap(\.string) ?? []
        m.vision = j["supports_vision"]?.bool ?? j["supports_images"]?.bool ?? false
        let lower = id.lowercased()
        let mediaOnly = ["image", "tts", "transcribe", "embed", "eleven_", "video", "whisper", "ocr"].contains { lower.contains($0) }
        m.chat = (j["supports_completions"]?.bool ?? true) && !mediaOnly
        return m
    }
}

/// The provider's model list (from /v1/models, cached on disk so the picker works offline).
@Observable
final class ModelCatalog {
    static let shared = ModelCatalog()
    private(set) var models: [ModelInfo] = []
    private(set) var error: String?
    private(set) var loading = false
    private var cacheURL: URL { Paths.support.appendingPathComponent("models-cache.json") }

    private init() {
        if let data = try? Data(contentsOf: cacheURL), let j = JSON.parse(String(decoding: data, as: UTF8.self)) {
            models = Self.parseList(j)
        }
    }

    func info(_ id: String) -> ModelInfo? { models.first { $0.id == id } }
    var chatModels: [ModelInfo] { models.filter(\.chat) }

    nonisolated static func parseList(_ j: JSON) -> [ModelInfo] {
        (j["data"]?.array ?? j.array ?? []).compactMap(ModelInfo.parse).sorted { $0.id < $1.id }
    }

    func refresh() async {
        let s = AppSettings.shared
        guard let base = URL(string: s.baseURL) else { error = "Set the provider base URL first."; return }
        loading = true
        defer { loading = false }
        var req = URLRequest(url: base.appendingPathComponent("v1/models"))
        req.timeoutInterval = 30
        if !s.apiKey.isEmpty { req.setValue("Bearer \(s.apiKey)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let j = JSON.parse(String(decoding: data, as: UTF8.self)) else {
                error = JSON.parse(String(decoding: data, as: UTF8.self))?["error"]?["message"]?.string ?? "The provider returned \(status)."
                return
            }
            let list = Self.parseList(j)
            guard !list.isEmpty else { error = "No models in the response."; return }
            models = list
            error = nil
            try? data.write(to: cacheURL)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
