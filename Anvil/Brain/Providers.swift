import Foundation

/// Where a model runs. Anvil offers exactly these three.
nonisolated enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case experiential, luna, gemini
    var id: String { rawValue }
    var label: String {
        switch self {
        case .experiential: return "Experiential Labs"
        case .luna: return "Luna API"
        case .gemini: return "Gemini (web proxy)"
        }
    }
    var symbol: String {
        switch self { case .experiential: return "bolt"; case .luna: return "moon"; case .gemini: return "sparkle" }
    }
}

nonisolated struct ModelChoice: Identifiable, Hashable, Sendable {
    var id: String
    var provider: Provider
    var detail: String = ""
}

nonisolated enum Providers {
    /// The Experiential Labs models Anvil offers (the gateway has many more; these are the ones that matter).
    static let experientialModels = ["glm-5.3-flash-uncensored", "glm-5.3-flash", "deepseek-v4.1-flash-uncensored", "deepseek-v4.1-flash"]
    static let defaultLunaURL = "https://overchat-completions-api.streamflix-one.workers.dev"
    static let defaultGeminiURL = "https://gemini.13-140-169-159.sslip.io"
    static let defaultLunaModels = ["gpt-6-luna"]
    static let defaultGeminiModels = ["gemini-auto"]

    static func provider(for model: String) -> Provider {
        if experientialModels.contains(model) { return .experiential }
        if model.hasPrefix("gemini") { return .gemini }
        return .luna
    }

    /// Models that read images themselves; others hand image turns to the vision model.
    static func seesImages(_ model: String) -> Bool {
        provider(for: model) == .gemini || model == "glm-5.3-flash"
    }
}

/// Client for the self-hosted Gemini web API (ported from Peep): an OpenAI-shaped chat endpoint with server-side sessions.
nonisolated final class GeminiWebClient: Sendable {
    let baseURL: URL
    let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 620
        cfg.timeoutIntervalForResource = 900
        cfg.httpAdditionalHeaders = ["User-Agent": "\(AppInfo.name)/\(AppInfo.version) (macOS)"]
        session = URLSession(configuration: cfg)
    }

    private func request(_ path: String, method: String = "POST", json: [String: Any]? = nil) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    private func send(_ req: URLRequest, attempts: Int = 4) async throws -> Data {
        var last: BrainError?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                let (data, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                let e = JSON.parse(String(decoding: data, as: UTF8.self))?["error"]
                let code = e?["code"]?.string ?? "http_\(status)"
                let err = BrainError(status: status, code: status == 401 || status == 403 || code == "unauthorized" ? "unauthorized" : code,
                                     message: e?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self),
                                     retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
                last = err
                guard ["server_busy", "not_ready", "upstream_blocked", "upstream_error"].contains(code), attempt < attempts - 1 else { throw err }
                try await Task.sleep(for: .seconds(err.retryAfter ?? Double(1 << attempt) * 1.5))
            } catch let e as BrainError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                last = BrainError(status: 0, code: "network", message: error.localizedDescription)
                if attempt < attempts - 1 { try await Task.sleep(for: .seconds(Double(attempt + 1) * 1.5)) }
            }
        }
        throw last ?? BrainError(status: 0, code: "network", message: "request failed")
    }

    func chat(_ messages: [ChatMessage], model: String?, sessionID: String?, temporary: Bool = true) async throws -> String {
        var body: [String: Any] = ["messages": OpenAIClient.messagesJSON(messages, images: true), "stream": false, "temporary": temporary]
        if let model { body["model"] = model }
        if let sessionID { body["session_id"] = sessionID }
        let data = try await send(try request("v1/chat/completions", json: body))
        guard let text = JSON.parse(String(decoding: data, as: UTF8.self))?["choices"]?.array?.first?["message"]?["content"]?.string else {
            throw BrainError(status: 200, code: "bad_response", message: "no content in the Gemini proxy's response")
        }
        return text
    }

    func models() async throws -> [String] {
        let data = try await send(try request("v1/models", method: "GET"), attempts: 1)
        return (JSON.parse(String(decoding: data, as: UTF8.self))?["data"]?.array ?? []).compactMap { $0["id"]?.string }
    }
}
