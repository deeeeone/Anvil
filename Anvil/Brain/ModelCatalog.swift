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

/// The models Anvil offers: four from Experiential Labs (with prices), everything the Luna API lists,
/// and the Gemini proxy's models. Lists are cached on disk so the picker works offline.
@Observable
final class ModelCatalog {
    static let shared = ModelCatalog()
    /// Experiential Labs pricing info for the offered models.
    private(set) var models: [ModelInfo] = []
    private(set) var lunaModels: [String] = Providers.defaultLunaModels
    private(set) var geminiModels: [String] = Providers.defaultGeminiModels
    private(set) var chatgptModels: [String] = Providers.defaultChatGPTModels
    private(set) var error: String?
    private(set) var loading = false
    private var cacheURL: URL { Paths.support.appendingPathComponent("models-cache.json") }

    private init() {
        if let data = try? Data(contentsOf: cacheURL), let j = JSON.parse(String(decoding: data, as: UTF8.self)) {
            models = Self.parseList(j["experiential"] ?? j)
            if let l = j["luna"]?.array?.compactMap(\.string), !l.isEmpty { lunaModels = l }
            if let g = j["gemini"]?.array?.compactMap(\.string), !g.isEmpty { geminiModels = g }
            if let c = j["chatgpt"]?.array?.compactMap(\.string), !c.isEmpty { chatgptModels = c }
        }
    }

    func info(_ id: String) -> ModelInfo? { models.first { $0.id == id } }

    /// Everything the picker shows, grouped by provider in a fixed order.
    var choices: [ModelChoice] {
        let exp = Providers.experientialModels.map { id in
            ModelChoice(id: id, provider: .experiential, detail: [info(id)?.priceLabel ?? "", info(id)?.contextLabel ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        let luna = lunaModels.map { ModelChoice(id: $0, provider: .luna, detail: "free") }
        let gem = geminiModels.map { ModelChoice(id: $0, provider: .gemini, detail: WebAccounts.shared.hasAny(.gemini) ? "free, your Google account" : "free, via your proxy") }
        let cg = chatgptModels.map { ModelChoice(id: $0, provider: .chatgpt, detail: WebAccounts.shared.hasAny(.chatgpt) ? "your ChatGPT plan" : "via the local proxy") }
        return exp + luna + gem + cg
    }

    /// Kept for older call sites: the offered Experiential models.
    var chatModels: [ModelInfo] { Providers.experientialModels.map { info($0) ?? ModelInfo(id: $0) } }

    nonisolated static func parseList(_ j: JSON) -> [ModelInfo] {
        (j["data"]?.array ?? j.array ?? []).compactMap(ModelInfo.parse).sorted { $0.id < $1.id }
    }

    /// Luna's list, with gpt-6-luna first.
    nonisolated static func lunaList(_ j: JSON) -> [String] {
        let ids = (j["data"]?.array ?? j.array ?? []).compactMap { $0["id"]?.string ?? $0.string }
        return ids.sorted { a, b in a == "gpt-6-luna" ? true : b == "gpt-6-luna" ? false : a < b }
    }

    /// The proxy also lists its upstream's models: keep only the chatgpt/* ones, auto first.
    nonisolated static func chatgptList(_ j: JSON) -> [String] {
        let ids = (j["data"]?.array ?? j.array ?? []).compactMap { $0["id"]?.string ?? $0.string }.filter { $0.hasPrefix("chatgpt/") }
        return ids.sorted { a, b in a == "chatgpt/auto" ? true : b == "chatgpt/auto" ? false : a < b }
    }

    func refresh() async {
        let s = AppSettings.shared
        loading = true
        defer { loading = false }
        var problems: [String] = []
        var cache: [String: Any] = [:]
        if s.hasKey, let base = URL(string: s.baseURL) {
            var req = URLRequest(url: base.appendingPathComponent("v1/models"))
            req.timeoutInterval = 30
            req.setValue("Bearer \(s.apiKey)", forHTTPHeaderField: "Authorization")
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               let j = JSON.parse(String(decoding: data, as: UTF8.self)) {
                models = Self.parseList(j).filter { Providers.experientialModels.contains($0.id) }
            } else { problems.append("Experiential Labs") }
        }
        if let base = URL(string: s.lunaURL) {
            var req = URLRequest(url: base.appendingPathComponent("v1/models"))
            req.timeoutInterval = 30
            if let (data, _) = try? await URLSession.shared.data(for: req), let j = JSON.parse(String(decoding: data, as: UTF8.self)) {
                let l = Self.lunaList(j)
                if !l.isEmpty { lunaModels = l }
            } else { problems.append("Luna API") }
        }
        if !s.geminiKey.isEmpty, let base = URL(string: s.geminiURL) {
            if let l = try? await GeminiProxyClient(baseURL: base, apiKey: s.geminiKey).models(), !l.isEmpty { geminiModels = l }
            else if !WebAccounts.shared.hasAny(.gemini) { problems.append("Gemini proxy") }
        }
        if let base = URL(string: s.chatgptURL), await ChatGPTProxy.shared.check() {
            var req = URLRequest(url: base.appendingPathComponent("v1/models"))
            req.timeoutInterval = 10
            if let (data, _) = try? await URLSession.shared.data(for: req), let j = JSON.parse(String(decoding: data, as: UTF8.self)) {
                let l = Self.chatgptList(j)
                if !l.isEmpty { chatgptModels = l }
            }
        }
        error = problems.isEmpty ? nil : "Couldn't reach: " + problems.joined(separator: ", ")
        cache["experiential"] = ["data": models.map { m -> [String: Any] in
            var o: [String: Any] = ["id": m.id]
            if let c = m.contextTokens { o["context_window_tokens"] = c }
            var p: [String: Any] = [:]
            if let v = m.inputPerMillion { p["input_nano_usd_per_million_tokens"] = v * 1_000_000_000 }
            if let v = m.outputPerMillion { p["output_nano_usd_per_million_tokens"] = v * 1_000_000_000 }
            if let v = m.cachedInputPerMillion { p["cached_input_nano_usd_per_million_tokens"] = v * 1_000_000_000 }
            o["pricing"] = p
            return o
        }]
        cache["luna"] = lunaModels
        cache["gemini"] = geminiModels
        cache["chatgpt"] = chatgptModels
        if let data = try? JSONSerialization.data(withJSONObject: cache) { try? data.write(to: cacheURL) }
    }
}
