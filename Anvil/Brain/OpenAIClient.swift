import Foundation

/// Stateless OpenAI-compatible chat client. The caller sends the full history.
nonisolated final class OpenAIClient: Sendable {
    let baseURL: URL
    let apiKey: String
    let endpoint: Endpoint
    private let session: URLSession

    /// How a particular OpenAI-compatible server wants to be called. The defaults match Anvil's built-in providers;
    /// provider plugins describe theirs in `anvil-provider.json`.
    struct Endpoint: Sendable, Equatable {
        var chatPath = "v1/chat/completions"
        var authHeader = "Authorization"
        var authPrefix = "Bearer "
        var headers: [String: String] = [:]
        var maxTokensField = "max_tokens"
        var sendsStop = true
        var sendsEffort = true
        var streamUsage = true
        /// Extra body fields (from a provider plugin's spec).
        var extraBody: [String: JSON] = [:]
        static let standard = Endpoint()
    }

    init(baseURL: URL, apiKey: String, endpoint: Endpoint = .standard) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.endpoint = endpoint
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 600
        cfg.httpAdditionalHeaders = ["User-Agent": "\(AppInfo.name)/\(AppInfo.version) (macOS)"]
        session = URLSession(configuration: cfg)
    }

    static func messagesJSON(_ messages: [ChatMessage], images: Bool) -> [[String: Any]] {
        messages.map { m in
            if !images || !m.hasImage { return ["role": m.role, "content": m.text] }
            let parts: [[String: Any]] = m.parts.map {
                switch $0 {
                case .text(let t): return ["type": "text", "text": t]
                case .image(let d, let mime): return ["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(d.base64EncodedString())"]]
                }
            }
            return ["role": m.role, "content": parts]
        }
    }

    /// `effort`: "low"/"medium"/"high"/"max" for reasoning models (nil = provider default).
    /// The model must stop after its JSON block; these catch it starting to write the app's observation itself.
    static let agentStops = ["<observation", "**Observation", "\nObservation:", "</observation>"]

    /// The POST request for one chat call, shaped the way this endpoint wants it.
    func request(_ messages: [ChatMessage], model: String, sendImages: Bool, effort: String?, stop: [String]?,
                 maxTokens: Int?, stream: Bool) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(endpoint.chatPath))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(endpoint.authPrefix + apiKey, forHTTPHeaderField: endpoint.authHeader) }
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        var body: [String: Any] = ["model": model, "messages": Self.messagesJSON(messages, images: sendImages), "stream": stream]
        if stream && endpoint.streamUsage { body["stream_options"] = ["include_usage": true] }
        if let effort, !effort.isEmpty, endpoint.sendsEffort { body["reasoning_effort"] = effort }
        if let stop, !stop.isEmpty, endpoint.sendsStop { body["stop"] = stop }
        if let maxTokens { body[endpoint.maxTokensField] = maxTokens }
        for (k, v) in endpoint.extraBody where !["model", "messages", "stream"].contains(k) { body[k] = v.anyValue }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    func chat(_ messages: [ChatMessage], model: String, sendImages: Bool = false, effort: String? = nil,
              stop: [String]? = nil, maxTokens: Int? = nil, attempts: Int = 3) async throws -> (text: String, usage: ChatUsage?) {
        let req = try request(messages, model: model, sendImages: sendImages, effort: effort, stop: stop, maxTokens: maxTokens, stream: false)

        var last: BrainError?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                let (data, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let j = JSON.parse(String(decoding: data, as: UTF8.self))
                if (200..<300).contains(status), let text = j?["choices"]?.array?.first?["message"]?["content"]?.string, !text.isEmpty || maxTokens != nil {
                    var usage = j?["usage"].map { u in
                        ChatUsage(prompt: u["prompt_tokens"]?.int ?? 0, completion: u["completion_tokens"]?.int ?? 0,
                                  cached: u["prompt_tokens_details"]?["cached_tokens"]?.int ?? 0, cost: u["cost"]?.double)
                    }
                    usage?.finishReason = j?["choices"]?.array?.first?["finish_reason"]?.string
                    return (text, usage)
                }
                let msg = j?["error"]?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self)
                let code = status == 429 ? "server_busy" : status == 401 || status == 403 ? "unauthorized" : (200..<300).contains(status) ? "bad_response" : "upstream_error"
                last = BrainError(status: status, code: code, message: msg,
                                  retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
                if code == "unauthorized" || (400..<500).contains(status) && status != 429 && status != 408 { throw last! }
            } catch let e as BrainError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                last = BrainError(status: 0, code: (error as? URLError)?.code == .timedOut ? "upstream_timeout" : "network", message: error.localizedDescription)
            }
            if attempt < attempts - 1 { try await Task.sleep(for: .seconds(min(10, last?.retryAfter ?? Double(2 * (attempt + 1))))) }
        }
        throw last ?? BrainError(status: 0, code: "network", message: "request failed")
    }

    /// Streaming chat. `onText` gets the accumulated text; return true from `shouldStop` to end the stream early
    /// (the reply is complete, the model would only keep talking). Usage comes from the final chunk when the stream runs out.
    func chatStream(_ messages: [ChatMessage], model: String, sendImages: Bool = false, effort: String? = nil, stop: [String]? = nil,
                    maxTokens: Int? = nil, onText: @escaping (String) -> Void, shouldStop: @escaping (String) -> Bool) async throws -> (text: String, usage: ChatUsage?, cut: Bool) {
        let req = try request(messages, model: model, sendImages: sendImages, effort: effort, stop: stop, maxTokens: maxTokens, stream: true)
        return try await Self.consumeSSE(session: session, request: req, onText: onText, shouldStop: shouldStop)
    }

    /// Reads an OpenAI-style SSE stream. Shared with the Gemini proxy client.
    static func consumeSSE(session: URLSession, request: URLRequest, onText: @escaping (String) -> Void,
                           shouldStop: @escaping (String) -> Bool) async throws -> (text: String, usage: ChatUsage?, cut: Bool) {
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await session.bytes(for: request) } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            let code = (error as? URLError)?.code
            if code == .badServerResponse || code == .cannotParseResponse {
                throw BrainError(status: 0, code: "upstream_error",
                                 message: "the provider closed the connection before replying (often a rejected session)")
            }
            throw BrainError(status: 0, code: code == .timedOut ? "upstream_timeout" : "network", message: error.localizedDescription)
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 8000 { break } }
            let msg = JSON.parse(String(decoding: data, as: UTF8.self))?["error"]?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self)
            let code = status == 429 || status == 503 ? "server_busy" : status == 401 || status == 403 ? "unauthorized" : "upstream_error"
            throw BrainError(status: status, code: code, message: msg, retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        var text = ""
        var usage: ChatUsage?
        var lastEmit = Date.distantPast
        var finished = false
        var finishReason: String?
        do {
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { finished = true; break }
            guard let j = JSON.parse(payload) else { continue }
            if let e = j["error"] { throw BrainError(status: 200, code: e["code"]?.string ?? "stream_error", message: e["message"]?.string ?? "stream error") }
            if let u = j["usage"], u != .null {
                usage = ChatUsage(prompt: u["prompt_tokens"]?.int ?? 0, completion: u["completion_tokens"]?.int ?? 0,
                                  cached: u["prompt_tokens_details"]?["cached_tokens"]?.int ?? 0, cost: u["cost"]?.double)
            }
            if let fr = j["choices"]?.array?.first?["finish_reason"], fr != .null { finished = true; finishReason = fr.string }
            if let d = j["choices"]?.array?.first?["delta"]?["content"]?.string, !d.isEmpty {
                text += d
                if Date().timeIntervalSince(lastEmit) > 0.08 { onText(text); lastEmit = Date() }
                if d.contains("`") && shouldStop(text) { onText(text); return (text, usage, true) }
            }
        }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if text.isEmpty {
                throw BrainError(status: status, code: "upstream_error",
                                 message: "the provider closed the stream before replying (often a rejected session)")
            }
            if !Brain.replyComplete(text) { throw BrainError(status: status, code: "network", message: "the reply stream ended early") }
        }
        onText(text)
        if text.isEmpty { throw BrainError(status: status, code: "bad_response", message: "empty reply") }
        // The connection dropped mid-reply: don't pass a truncated reply off as complete.
        if !finished && !Brain.replyComplete(text) { throw BrainError(status: status, code: "network", message: "the reply stream ended early") }
        var u = usage ?? (finishReason != nil ? ChatUsage() : nil)
        u?.finishReason = finishReason
        return (text, u, false)
    }
}
