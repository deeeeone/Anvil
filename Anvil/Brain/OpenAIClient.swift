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
    func chat(_ messages: [ChatMessage], model: String, sendImages: Bool = false, effort: String? = nil,
              attempts: Int = 3) async throws -> (text: String, usage: ChatUsage?) {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": model, "messages": Self.messagesJSON(messages, images: sendImages), "stream": false]
        if let effort, !effort.isEmpty { body["reasoning_effort"] = effort }
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
}
