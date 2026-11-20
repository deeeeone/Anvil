import Foundation

nonisolated enum ChatPart: Sendable, Equatable {
    case text(String)
    case image(Data, String)
}

/// One message of the model conversation (user or assistant). Images are dropped when persisted.
nonisolated struct ChatMessage: Sendable, Equatable, Codable {
    var role: String
    var parts: [ChatPart]

    static func user(_ text: String, images: [(Data, String)] = []) -> ChatMessage {
        ChatMessage(role: "user", parts: [.text(text)] + images.map { .image($0.0, $0.1) })
    }
    static func assistant(_ text: String) -> ChatMessage { ChatMessage(role: "assistant", parts: [.text(text)]) }

    var text: String { parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: "\n") }
    var hasImage: Bool { parts.contains { if case .image = $0 { return true } else { return false } } }
    var charCount: Int { parts.reduce(0) { n, p in if case .text(let t) = p { return n + t.count } else { return n + 3000 } } }

    enum CodingKeys: String, CodingKey { case role, text, images }
    init(role: String, parts: [ChatPart]) { self.role = role; self.parts = parts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        let t = try c.decode(String.self, forKey: .text)
        let imgs = try c.decodeIfPresent(Int.self, forKey: .images) ?? 0
        parts = [.text(t + (imgs > 0 ? "\n[\(imgs) image(s) omitted]" : ""))]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        let n = parts.filter { if case .image = $0 { return true } else { return false } }.count
        if n > 0 { try c.encode(n, forKey: .images) }
    }
}

/// Token counts and the provider's own cost figure for one call.
nonisolated struct ChatUsage: Sendable, Codable, Equatable {
    var prompt = 0
    var completion = 0
    var cached = 0
    var cost: Double?
}

nonisolated struct BrainError: Error, LocalizedError, Sendable {
    var status: Int
    var code: String
    var message: String
    var retryAfter: Double?

    var errorDescription: String? {
        switch code {
        case "unauthorized": return "The provider rejected the API key. Check it in Settings."
        case "server_busy": return "The provider is rate limiting (HTTP 429). Try again in a moment."
        case "upstream_timeout": return "The model took too long to answer."
        case "network": return "Couldn't reach the provider: \(message)"
        case "no_key": return message.isEmpty ? "No API key yet for this model's provider. Add one in Settings (or import keys from Peep)." : message
        default: return "Provider error \(status): \(Fmt.line(message, 200))"
        }
    }
}
