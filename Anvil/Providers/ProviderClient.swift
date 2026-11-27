import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to one provider plugin: over HTTP for "openai" plugins, through its command for "process" plugins.
struct ProviderClient {
    let provider: InstalledProvider
    private let key: String
    private let session: ProviderPlugins.Session

    init(_ p: InstalledProvider) {
        provider = p
        (key, session) = ProviderPlugins.shared.credentials(p)
    }

    private var spec: ProviderSpec { provider.spec }

    private func http() throws -> OpenAIClient {
        guard let base = URL(string: ProviderPlugins.shared.baseURL(provider)) else { throw BrainError(status: 0, code: "no_key", message: "\(spec.name) has no baseURL") }
        return OpenAIClient(baseURL: base, apiKey: key, endpoint: spec.endpoint())
    }

    // MARK: Chat

    /// One reply. `shouldStop` ends a stream early (used when the provider ignores stop sequences).
    func chat(_ history: [ChatMessage], model: String, images: Bool, effort: String?, stop: [String]?, maxTokens: Int?,
              onText: ((String) -> Void)?, shouldStop: @escaping (String) -> Bool) async throws -> (text: String, usage: ChatUsage?) {
        switch spec.type {
        case .openai:
            try await ProviderServers.shared.ensureRunning(provider)
            let client = try http()
            if let onText, spec.streams {
                let r = try await client.chatStream(history, model: model, sendImages: images, effort: effort, stop: stop, maxTokens: maxTokens,
                                                    onText: onText, shouldStop: shouldStop)
                return (r.text, r.usage)
            }
            return try await client.chat(history, model: model, sendImages: images, effort: effort, stop: stop, maxTokens: maxTokens)
        case .process:
            var request: [String: Any] = [
                "type": "chat", "model": model, "stream": onText != nil,
                "messages": history.map { m -> [String: Any] in
                    var o: [String: Any] = ["role": m.role, "content": m.text]
                    if images, m.hasImage {
                        o["images"] = m.parts.compactMap { p -> [String: String]? in
                            if case .image(let d, let mime) = p { return ["mime": mime, "data": d.base64EncodedString()] }
                            return nil
                        }
                    }
                    return o
                },
            ]
            if let stop, !stop.isEmpty { request["stop"] = stop }
            if let maxTokens { request["max_tokens"] = maxTokens }
            if let effort, !effort.isEmpty { request["effort"] = effort }
            var text = ""
            var usage: ChatUsage?
            try await run(request) { event in
                switch event["type"]?.string {
                case "delta":
                    text += event["text"]?.string ?? ""
                    onText?(text)
                    return shouldStop(text) ? .stop : .more
                case "done":
                    if let t = event["text"]?.string, text.isEmpty { text = t }
                    if let u = event["usage"] {
                        usage = ChatUsage(prompt: u["prompt"]?.int ?? u["prompt_tokens"]?.int ?? 0,
                                          completion: u["completion"]?.int ?? u["completion_tokens"]?.int ?? 0,
                                          cached: 0, cost: u["cost"]?.double)
                    }
                    return .stop
                default:
                    return .more
                }
            }
            if text.isEmpty { throw BrainError(status: 0, code: "bad_response", message: "\(spec.name) returned an empty reply") }
            return (text, usage)
        }
    }

    // MARK: Models

    func listModels() async throws -> [ProviderSpec.Model] {
        switch spec.type {
        case .openai:
            try await ProviderServers.shared.ensureRunning(provider)
            let path = spec.modelsPath ?? "models"
            guard !path.isEmpty, let base = URL(string: ProviderPlugins.shared.baseURL(provider)) else { return [] }
            let e = spec.endpoint()
            var req = URLRequest(url: base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
            req.timeoutInterval = 30
            if !key.isEmpty { req.setValue(e.authPrefix + key, forHTTPHeaderField: e.authHeader) }
            for (k, v) in e.headers { req.setValue(v, forHTTPHeaderField: k) }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let j = JSON.parse(String(decoding: data, as: UTF8.self)) else {
                throw BrainError(status: status, code: status == 401 || status == 403 ? "unauthorized" : "upstream_error",
                                 message: status == 401 || status == 403 ? "the key was rejected" : "HTTP \(status)")
            }
            return Self.parseModels(j)
        case .process:
            var out: [ProviderSpec.Model] = []
            try await run(["type": "models"]) { event in
                if event["type"]?.string == "models" { out = Self.parseModels(event); return .stop }
                return .more
            }
            return out
        }
    }

    /// `{"data": [{"id"...}]}` (OpenAI) or `{"models": [...]}` (process plugins), with optional vision, context and prices.
    static func parseModels(_ j: JSON) -> [ProviderSpec.Model] {
        let list = j["data"]?.array ?? j["models"]?.array ?? j.array ?? []
        return list.compactMap { m in
            guard let id = m["id"]?.string ?? m.string, !id.isEmpty else { return nil }
            return ProviderSpec.Model(id: id, name: m["name"]?.string, vision: m["vision"]?.bool,
                                      context: m["context"]?.int ?? m["context_length"]?.int,
                                      input: m["input"]?.double, output: m["output"]?.double)
        }
    }

    // MARK: Process protocol

    enum Next { case more, stop }

    /// Runs the plugin's command with one request on stdin and hands each JSON line it prints to `onEvent`.
    /// `error` events become BrainErrors; cookies a `done` event reports are saved for the next request.
    func run(_ request: [String: Any], timeout: Double = 600, onEvent: @escaping (JSON) throws -> Next) async throws {
        var req = request
        var creds: [String: Any] = [:]
        if !key.isEmpty { creds["apiKey"] = key }
        if !session.cookies.isEmpty { creds["cookies"] = session.cookies }
        if !session.localStorage.isEmpty { creds["localStorage"] = session.localStorage }
        req["credentials"] = creds
        req["protocol"] = ProviderSpec.version
        let line = try JSONSerialization.data(withJSONObject: req) + Data("\n".utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = spec.command ?? []
        p.currentDirectoryURL = provider.folder
        var env = ProcessRunner.environment()
        env["ANVIL_PROVIDER_PROTOCOL"] = "\(ProviderSpec.version)"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let stderr = OutputBuffer()
#if canImport(Darwin)
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { stderr.append(String(decoding: d, as: UTF8.self)) }
        }
#else
        PipeReader.start(errPipe.fileHandleForReading, onData: { stderr.append(String(decoding: $0, as: UTF8.self)) }, onEOF: {})
#endif
        let lines = AsyncStream<String> { cont in
            let splitter = LineSplitter()
#if canImport(Darwin)
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil; for l in splitter.finish() { cont.yield(l) }; cont.finish(); return }
                for l in splitter.feed(d) { cont.yield(l) }
            }
#else
            PipeReader.start(outPipe.fileHandleForReading, onData: { d in
                for l in splitter.feed(d) { cont.yield(l) }
            }, onEOF: {
                for l in splitter.finish() { cont.yield(l) }
                cont.finish()
            })
#endif
        }
        do { try p.run() } catch {
            throw BrainError(status: 0, code: "no_key", message: "\(spec.name) couldn't start \((spec.command ?? []).joined(separator: " ")): \(error.localizedDescription)")
        }
        try? inPipe.fileHandleForWriting.write(contentsOf: line)
        try? inPipe.fileHandleForWriting.close()

        let id = provider.id
        let name = spec.name
        let watchdog = Task { try? await Task.sleep(for: .seconds(timeout)); if p.isRunning { p.terminate() } }
        defer { watchdog.cancel(); if p.isRunning { p.terminate() } }
        var ended = false
        try await withTaskCancellationHandler {
            for await l in lines {
                guard let event = JSON.parse(l) else { continue }   // tolerate stray prints
                if event["type"]?.string == "error" {
                    let code = event["code"]?.string ?? "upstream_error"
                    let mapped = ["unauthorized": "unauthorized", "rate_limited": "server_busy", "too_long": "too_long"][code] ?? "upstream_error"
                    throw BrainError(status: code == "unauthorized" ? 401 : 0, code: mapped, message: "\(name): " + (event["message"]?.string ?? code))
                }
                if event["type"]?.string == "done", let c = event["credentials"]?["cookies"]?.object {
                    ProviderPlugins.shared.updateSession(id, cookies: c.compactMapValues(\.string))
                }
                if try onEvent(event) == .stop { ended = true; break }
            }
        } onCancel: {
            p.terminate()
        }
        if Task.isCancelled { throw CancellationError() }
        if !ended {
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let err = stderr.value.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BrainError(status: 0, code: "upstream_error", message: "\(name) exited with status \(p.terminationStatus)" + (err.isEmpty ? "" : ": " + Fmt.line(err, 400)))
            }
            throw BrainError(status: 0, code: "bad_response", message: "\(name) ended without a \"done\" event")
        }
    }
}

/// Splits a byte stream into lines.
nonisolated final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        var out: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            out.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return out
    }

    func finish() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let rest = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = Data()
        return rest.isEmpty ? [] : [rest]
    }
}
