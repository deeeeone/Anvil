import Foundation

/// Learns how many characters of conversation one token is worth for each model, from the token counts providers
/// report back on every call. A flat 3.5 characters per token is wrong by 30% or more for some models and for
/// non-English text; this keeps a running average per model, so the context estimate and auto-compaction follow
/// what the provider actually bills. (Providers do not publish their tokenizers in a form a Mac app can run.)
nonisolated final class TokenCalibrator: @unchecked Sendable {
    static let shared = TokenCalibrator(file: Paths.support.appendingPathComponent("token-ratios.json"))
    static let defaultRatio = 3.5

    private let lock = NSLock()
    private var ratios: [String: Double] = [:]
    private var samples: [String: Int] = [:]
    private let file: URL?

    init(file: URL? = nil) {
        self.file = file
        if let file, let d = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: [Double]].self, from: d) {
            for (k, v) in saved where v.count == 2 { ratios[k] = v[0]; samples[k] = Int(v[1]) }
        }
    }

    private static func key(_ model: String?) -> String { (model ?? "").lowercased() }

    /// Characters per token for `model` (3.5 until a call has been measured).
    func ratio(for model: String?) -> Double {
        lock.lock(); defer { lock.unlock() }
        return ratios[Self.key(model)] ?? Self.defaultRatio
    }

    /// How many calls the ratio for `model` is based on (0 = still the default).
    func sampleCount(for model: String?) -> Int {
        lock.lock(); defer { lock.unlock() }
        return samples[Self.key(model)] ?? 0
    }

    /// One call measured: `chars` of conversation came to `tokens` prompt tokens.
    func learn(model: String?, chars: Int, tokens: Int) {
        // Tiny prompts are dominated by fixed overhead (role markers, hidden system prompts), so they say little.
        guard tokens >= 400, chars >= 400 else { return }
        let measured = min(8, max(1.2, Double(chars) / Double(tokens)))
        let k = Self.key(model)
        lock.lock()
        let n = samples[k] ?? 0
        // The first measurement replaces the default; later ones move the average gently.
        ratios[k] = n == 0 ? measured : ratios[k]! * 0.75 + measured * 0.25
        samples[k] = n + 1
        let snapshot = ratios.mapValues { $0 }.reduce(into: [String: [Double]]()) { $0[$1.key] = [$1.value, Double(samples[$1.key] ?? 0)] }
        lock.unlock()
        if n % 5 == 0, let file, let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: file, options: .atomic) }
    }

    func tokens(chars: Int, model: String?) -> Int { Int((Double(chars) / ratio(for: model)).rounded()) }
}

/// What the composer's context bar shows: how full the window is and how much of the last request came from cache.
nonisolated struct ContextGauge: Equatable, Sendable {
    var used: Int
    /// Tokens of the last request the provider served from its prompt cache.
    var cached: Int
    /// The model's context window, when known.
    var window: Int?
    /// The figure comes from the provider's own count of the last request (not from our estimate).
    var measured: Bool

    init(lastPrompt: Int, lastCached: Int, estimate: Int, window: Int?) {
        measured = lastPrompt > 0 && lastPrompt >= estimate
        used = max(lastPrompt, estimate)
        cached = min(max(0, lastCached), max(lastPrompt, 0))
        self.window = window.flatMap { $0 > 0 ? $0 : nil }
    }

    /// 0...1 of the window in use (0 when the window is unknown).
    var fill: Double { window.map { min(1, Double(used) / Double($0)) } ?? 0 }
    /// 0...1 of the window the cached tokens take up.
    var cachedFill: Double { window.map { min(fill, Double(cached) / Double($0)) } ?? 0 }
    /// Share of the last request's prompt that was a cache hit.
    var hitRate: Double? { measured && used > 0 && cached > 0 ? Double(cached) / Double(used) : nil }
    var nearlyFull: Bool { fill >= 0.8 }

    var label: String {
        var s = (measured ? "" : "~") + Fmt.tokens(used)
        if let w = window { s += " / " + Fmt.tokens(w) }
        if let h = hitRate { s += " · \(Int((h * 100).rounded()))% cached" }
        return s
    }

    var help: String {
        var s = "Context: \(measured ? "" : "about ")\(used.formatted()) tokens"
        if let w = window { s += " of \(w.formatted()) (\(Int((fill * 100).rounded()))%)" }
        s += ". "
        if let h = hitRate { s += "\(cached.formatted()) tokens (\(Int((h * 100).rounded()))%) of the last request were served from the provider's cache, which is billed at a lower rate. " }
        s += measured ? "Counted by the provider on the last request. " : "Estimated from the conversation length. "
        s += "/compact frees space."
        return s
    }
}
