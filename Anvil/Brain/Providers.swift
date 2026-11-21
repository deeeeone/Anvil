import Foundation
import Observation

/// Where a model runs. Anvil offers exactly these three.
nonisolated enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case experiential, luna, gemini, chatgpt
    var id: String { rawValue }
    var label: String {
        switch self {
        case .experiential: return "Experiential Labs"
        case .luna: return "Luna API"
        case .gemini: return "Gemini (web)"
        case .chatgpt: return "ChatGPT (web)"
        }
    }
    var symbol: String {
        switch self { case .experiential: return "bolt"; case .luna: return "moon"; case .gemini: return "sparkle"; case .chatgpt: return "bubble.left.and.text.bubble.right" }
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
    /// zhaees/chatgpt-proxy (toolcall-middleware) runs here by default.
    static let defaultChatGPTURL = "http://127.0.0.1:1435"
    static let defaultChatGPTModels = ["chatgpt/auto", "chatgpt/gpt-5.5", "chatgpt/gpt-5.5-thinking", "chatgpt/gpt-5.4-thinking", "chatgpt/gpt-5.3",
                                       "chatgpt/gpt-5-mini", "chatgpt/o4-mini", "chatgpt/o3", "chatgpt/gpt-4.1", "chatgpt/gpt-4o"]
    static let defaultLunaModels = ["gpt-6-luna"]
    static let defaultGeminiModels = ["gemini-auto", "gemini-pro", "gemini-flash", "gemini-flash-lite"]

    static func provider(for model: String) -> Provider {
        if experientialModels.contains(model) { return .experiential }
        if model.hasPrefix("chatgpt/") { return .chatgpt }
        if model.hasPrefix("gemini") { return .gemini }
        return .luna
    }

    /// Models that read images themselves; others hand image turns to the vision model.
    static func seesImages(_ model: String) -> Bool {
        provider(for: model) == .gemini || model == "glm-5.3-flash"
    }
}

/// Client for a self-hosted Gemini web API: an OpenAI-shaped chat endpoint with server-side sessions.
nonisolated final class GeminiProxyClient: Sendable {
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

    func chatStream(_ messages: [ChatMessage], model: String?, sessionID: String?, temporary: Bool = true,
                    onText: @escaping (String) -> Void, shouldStop: @escaping (String) -> Bool) async throws -> (text: String, cut: Bool) {
        var body: [String: Any] = ["messages": OpenAIClient.messagesJSON(messages, images: true), "stream": true, "temporary": temporary]
        if let model { body["model"] = model }
        if let sessionID { body["session_id"] = sessionID }
        let r = try await OpenAIClient.consumeSSE(session: session, request: try request("v1/chat/completions", json: body), onText: onText, shouldStop: shouldStop)
        return (r.text, r.cut)
    }

    func models() async throws -> [String] {
        let data = try await send(try request("v1/models", method: "GET"), attempts: 1)
        return (JSON.parse(String(decoding: data, as: UTF8.self))?["data"]?.array ?? []).compactMap { $0["id"]?.string }
    }
}


/// Starts and stops a local copy of the ChatGPT web proxy (zhaees/chatgpt-proxy) from the folder you cloned it to.
/// Anvil only talks to it over its OpenAI-compatible API; the proxy handles ChatGPT itself.
@Observable
final class ChatGPTProxy {
    static let shared = ChatGPTProxy()
    private(set) var running = false
    private(set) var status = ""
    @ObservationIgnored private var process: Process?

    /// Does the proxy answer at the configured URL?
    func check() async -> Bool {
        guard let base = URL(string: AppSettings.shared.chatgptURL) else { return false }
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 3
        let ok = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
        running = ok
        return ok
    }

    /// Starts `start.sh` in the configured folder if the proxy isn't already answering, and waits for it (up to 40 s).
    @discardableResult
    func ensureRunning() async -> String? {
        if await check() { status = "Running"; return nil }
        let folder = AppSettings.shared.chatgptProxyFolder
        guard !folder.isEmpty, FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("start.sh")) else {
            status = "Not running"
            return "The ChatGPT proxy isn't running at \(AppSettings.shared.chatgptURL). Start it (./start.sh in its folder), or set its folder in Settings so Anvil can start it."
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["start.sh"]
        p.currentDirectoryURL = URL(fileURLWithPath: folder)
        p.environment = ProcessRunner.environment()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { status = "Couldn't start"; return "Couldn't start the ChatGPT proxy: \(error.localizedDescription)" }
        process = p
        status = "Starting"
        for _ in 0..<40 {
            try? await Task.sleep(for: .seconds(1))
            if await check() { status = "Running"; return nil }
            if !p.isRunning { break }
        }
        status = "Failed to start"
        return "The ChatGPT proxy didn't come up. Run ./start.sh in \(folder) to see why (it needs bun, python3 and curl_cffi, and fresh ChatGPT cookies in .env)."
    }

    func stop() {
        if let p = process, p.isRunning { ProcessRunner.killTree(p.processIdentifier) }
        process = nil
        running = false
        status = "Stopped"
    }
}
