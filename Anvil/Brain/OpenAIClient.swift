import Foundation

/// Stateless OpenAI-compatible chat client. The caller sends the full history.
nonisolated final class OpenAIClient: Sendable {
    let baseURL: URL
    let apiKey: String
    private let session: URLSession

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
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

    func chat(_ messages: [ChatMessage], model: String, sendImages: Bool = false, effort: String? = nil,
              stop: [String]? = nil, attempts: Int = 3) async throws -> (text: String, usage: ChatUsage?) {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": model, "messages": Self.messagesJSON(messages, images: sendImages), "stream": false]
        if let effort, !effort.isEmpty { body["reasoning_effort"] = effort }
        if let stop, !stop.isEmpty { body["stop"] = stop }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var last: BrainError?
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do {
                let (data, resp) = try await session.data(for: req)
                let http = resp as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                let j = JSON.parse(String(decoding: data, as: UTF8.self))
                if (200..<300).contains(status), let text = j?["choices"]?.array?.first?["message"]?["content"]?.string, !text.isEmpty {
                    let usage = j?["usage"].map { u in
                        ChatUsage(prompt: u["prompt_tokens"]?.int ?? 0, completion: u["completion_tokens"]?.int ?? 0,
                                  cached: u["prompt_tokens_details"]?["cached_tokens"]?.int ?? 0, cost: u["cost"]?.double)
                    }
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
                    onText: @escaping (String) -> Void, shouldStop: @escaping (String) -> Bool) async throws -> (text: String, usage: ChatUsage?, cut: Bool) {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": model, "messages": Self.messagesJSON(messages, images: sendImages), "stream": true,
                                   "stream_options": ["include_usage": true]]
        if let effort, !effort.isEmpty { body["reasoning_effort"] = effort }
        if let stop, !stop.isEmpty { body["stop"] = stop }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await Self.consumeSSE(session: session, request: req, onText: onText, shouldStop: shouldStop)
    }

    /// Reads an OpenAI-style SSE stream. Shared with the Gemini proxy client.
    static func consumeSSE(session: URLSession, request: URLRequest, onText: @escaping (String) -> Void,
                           shouldStop: @escaping (String) -> Bool) async throws -> (text: String, usage: ChatUsage?, cut: Bool) {
        let bytes: URLSession.AsyncBytes, resp: URLResponse
        do { (bytes, resp) = try await session.bytes(for: request) } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BrainError(status: 0, code: (error as? URLError)?.code == .timedOut ? "upstream_timeout" : "network", message: error.localizedDescription)
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 8000 { break } }
            let msg = JSON.parse(String(decoding: data, as: UTF8.self))?["error"]?["message"]?.string ?? String(decoding: data.prefix(300), as: UTF8.self)
            let code = status == 429 ? "server_busy" : status == 401 || status == 403 ? "unauthorized" : "upstream_error"
            throw BrainError(status: status, code: code, message: msg, retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init))
        }
        var text = ""
        var usage: ChatUsage?
        var lastEmit = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let j = JSON.parse(payload) else { continue }
            if let e = j["error"] { throw BrainError(status: 200, code: e["code"]?.string ?? "stream_error", message: e["message"]?.string ?? "stream error") }
            if let u = j["usage"], u != .null {
                usage = ChatUsage(prompt: u["prompt_tokens"]?.int ?? 0, completion: u["completion_tokens"]?.int ?? 0,
                                  cached: u["prompt_tokens_details"]?["cached_tokens"]?.int ?? 0, cost: u["cost"]?.double)
            }
            if let d = j["choices"]?.array?.first?["delta"]?["content"]?.string, !d.isEmpty {
                text += d
                if Date().timeIntervalSince(lastEmit) > 0.08 { onText(text); lastEmit = Date() }
                if d.contains("`") && shouldStop(text) { onText(text); return (text, usage, true) }
            }
        }
        onText(text)
        if text.isEmpty { throw BrainError(status: status, code: "bad_response", message: "empty reply") }
        return (text, usage, false)
    }
}
