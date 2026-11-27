import Foundation
#if canImport(AppKit)
import AppKit
#endif
import Observation

// Model Context Protocol client: spawns the stdio servers listed in Application Support/Anvil/mcp.json
// and the project's .mcp.json (Claude's format) and exposes their tools to the agent.

// MARK: Config

nonisolated struct MCPServerConfig: Sendable, Equatable {
    var name: String
    var command: String?
    var args: [String] = []
    var env: [String: String] = [:]
    var url: String?
    var disabled = false

    /// Parses `{"mcpServers": {"name": {"command": ..., "args": [...], "env": {...}}}}`, sorted by name.
    static func parse(_ text: String) throws -> [MCPServerConfig] {
        guard let root = JSON.parse(text), case .object = root else { throw MCPError.badConfig("mcp.json isn't a JSON object") }
        guard let servers = root["mcpServers"]?.object else { return [] }
        return servers.keys.sorted().compactMap { name in
            guard let o = servers[name]?.object else { return nil }
            return MCPServerConfig(name: name,
                                   command: o["command"]?.string,
                                   args: o["args"]?.array?.compactMap(\.string) ?? [],
                                   env: (o["env"]?.object ?? [:]).compactMapValues(\.string),
                                   url: o["url"]?.string,
                                   disabled: o["disabled"]?.bool ?? false)
        }
    }

    static var fileURL: URL { Paths.support.appendingPathComponent("mcp.json") }

    static let template = """
    {
      "mcpServers": {
        "example-filesystem": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"],
          "disabled": true
        }
      }
    }

    """
}

nonisolated enum MCPError: Error, LocalizedError {
    case badConfig(String), timeout(String), closed(String), rpc(Int, String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .badConfig(let s): return s
        case .timeout(let m): return "timed out waiting for \(m)"
        case .closed(let s): return "server exited\(s.isEmpty ? "" : ": \(s)")"
        case .rpc(let c, let m): return "\(m) (\(c))"
        case .unsupported(let s): return s
        }
    }
}

// MARK: JSON-RPC framing (stdio transport: one JSON message per line)

nonisolated enum MCPFraming {
    static func request(id: Int, method: String, params: JSON?) -> Data {
        var o: [String: JSON] = ["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method)]
        if let params { o["params"] = params }
        return line(.object(o))
    }

    static func notification(method: String, params: JSON? = nil) -> Data {
        var o: [String: JSON] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { o["params"] = params }
        return line(.object(o))
    }

    static func response(id: JSON, result: JSON? = nil, error: (Int, String)? = nil) -> Data {
        var o: [String: JSON] = ["jsonrpc": .string("2.0"), "id": id]
        if let error { o["error"] = .object(["code": .number(Double(error.0)), "message": .string(error.1)]) }
        else { o["result"] = result ?? .object([:]) }
        return line(.object(o))
    }

    /// `compact` never emits raw newlines (they're escaped inside strings), so a line is a whole message.
    static func line(_ msg: JSON) -> Data { Data((msg.compact + "\n").utf8) }

    /// Splits a byte stream into messages; keeps any partial trailing line for the next chunk.
    struct Decoder {
        private var buffer = Data()

        mutating func feed(_ data: Data) -> [JSON] {
            buffer.append(data)
            var out: [JSON] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                let text = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let msg = JSON.parse(text), case .object = msg else { continue }  // skip log noise
                out.append(msg)
            }
            return out
        }
    }
}

// MARK: Schema → catalog signature

nonisolated enum MCPSchema {
    /// `{"path": str, "head?": int}`: required keys first, optional ones marked `?`, capped so the catalog stays short.
    static func signature(_ schema: JSON?, maxProps: Int = 6) -> String {
        guard let props = schema?["properties"]?.object, !props.isEmpty else { return "{}" }
        let required = Set(schema?["required"]?.array?.compactMap(\.string) ?? [])
        let names = props.keys.sorted { a, b in
            let ra = required.contains(a), rb = required.contains(b)
            return ra != rb ? ra : a < b
        }
        var parts = names.prefix(maxProps).map { n in
            "\"\(n)\(required.contains(n) ? "" : "?")\": \(typeName(props[n]))"
        }
        if names.count > maxProps { parts.append("…+\(names.count - maxProps)") }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    static func typeName(_ p: JSON?) -> String {
        guard let p else { return "any" }
        if let e = p["enum"]?.array?.compactMap(\.string), !e.isEmpty, e.count <= 4 {
            return e.map { "\"\($0)\"" }.joined(separator: "|")
        }
        var t = p["type"]?.string
        if t == nil, let ts = p["type"]?.array?.compactMap(\.string) { t = ts.first { $0 != "null" } }
        if t == nil, let any = (p["anyOf"] ?? p["oneOf"])?.array { return typeName(any.first { $0["type"]?.string != "null" }) }
        switch t {
        case "string": return "str"
        case "integer": return "int"
        case "number": return "num"
        case "boolean": return "bool"
        case "object": return "{…}"
        case "array": return "[\(typeName(p["items"]))]"
        default: return "any"
        }
    }

    /// First sentence/line of a tool description, clipped.
    static func summary(_ description: String?, max: Int = 140) -> String {
        let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return "MCP tool" }
        // First non-empty line, without markdown heading marks.
        var s = d.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces)) }.first { !$0.isEmpty } ?? d
        if let r = s.range(of: ". ") { s = String(s[..<r.lowerBound]) + "." }
        return s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }

    /// Catalog names must survive ActionParser.normalize (lowercased, - and spaces → _).
    static func toolName(server: String, tool: String) -> String {
        func clean(_ s: String) -> String {
            String(s.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        }
        return clean(server) + "." + clean(tool)
    }
}

// MARK: Stdio connection

nonisolated final class MCPStdioClient: @unchecked Sendable {
    let config: MCPServerConfig
    private let process = Process()
    private let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    private let lock = NSLock()
    private var decoder = MCPFraming.Decoder()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var stderrTail = ""
    private(set) var exited = false

    init(config: MCPServerConfig) { self.config = config }

    var lastStderr: String { lock.withLock { stderrTail } }

    func start() throws {
        guard let command = config.command, !command.isEmpty else { throw MCPError.badConfig("no command") }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + config.args.map { NSString(string: $0).expandingTildeInPath }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ProcessRunner.basePath + ":" + (env["PATH"] ?? "")
        env.removeValue(forKey: "ANVIL_API_KEY"); env.removeValue(forKey: "ANVIL_GEMINI_KEY")
        for (k, v) in config.env { env[k] = v }
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
#if canImport(Darwin)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { self?.received(d) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            guard let self else { return }
            lock.withLock { self.stderrTail = String((self.stderrTail + String(decoding: d, as: UTF8.self)).suffix(2000)) }
        }
#else
        PipeReader.start(stdoutPipe.fileHandleForReading, onData: { [weak self] d in self?.received(d) }, onEOF: {})
        PipeReader.start(stderrPipe.fileHandleForReading, onData: { [weak self] d in
            guard let self else { return }
            lock.withLock { self.stderrTail = String((self.stderrTail + String(decoding: d, as: UTF8.self)).suffix(2000)) }
        }, onEOF: {})
#endif
        process.terminationHandler = { [weak self] _ in self?.failAll(MCPError.closed(self?.lastStderr.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last ?? "")) }
        // A server that already exited must give us EPIPE on write, not a SIGPIPE that kills the app.
#if canImport(Darwin)
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
#endif
        try process.run()
    }

    func request(_ method: String, _ params: JSON? = nil, timeout: Double) async throws -> JSON {
        try await withCheckedThrowingContinuation { cont in
            let id: Int? = lock.withLock {
                if exited { return nil }
                let id = nextID; nextID += 1
                pending[id] = cont
                return id
            }
            guard let id else { cont.resume(throwing: MCPError.closed(lastStderr)); return }
            write(MCPFraming.request(id: id, method: method, params: params))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .failure(MCPError.timeout(method)))
            }
        }
    }

    func notify(_ method: String, _ params: JSON? = nil) { write(MCPFraming.notification(method: method, params: params)) }

    func stop() {
#if canImport(Darwin)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
#endif
        try? stdinPipe.fileHandleForWriting.close()   // most servers exit on EOF
        if process.isRunning { process.terminate() }
        failAll(MCPError.closed("stopped"))
    }

    private func write(_ data: Data) {
        guard lock.withLock({ !exited }) else { return }
        do { try stdinPipe.fileHandleForWriting.write(contentsOf: data) } catch { failAll(MCPError.closed(error.localizedDescription)) }
    }

    private func received(_ data: Data) {
        let msgs = lock.withLock { decoder.feed(data) }
        for m in msgs {
            if let method = m["method"]?.string {
                // A request from the server. We offer no client features beyond answering pings.
                if let id = m["id"] { write(MCPFraming.response(id: id, result: method == "ping" ? .object([:]) : nil,
                                                                 error: method == "ping" ? nil : (-32601, "method not supported"))) }
                continue
            }
            guard let id = m["id"]?.int else { continue }
            if let err = m["error"] {
                resolve(id, .failure(MCPError.rpc(err["code"]?.int ?? 0, err["message"]?.string ?? "error")))
            } else {
                resolve(id, .success(m["result"] ?? .null))
            }
        }
    }

    private func resolve(_ id: Int, _ r: Result<JSON, Error>) {
        let cont = lock.withLock { pending.removeValue(forKey: id) }
        cont?.resume(with: r)
    }

    private func failAll(_ e: Error) {
        let conts = lock.withLock { () -> [CheckedContinuation<JSON, Error>] in
            exited = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for c in conts { c.resume(throwing: e) }
    }
}

// MARK: Tool wrapping

nonisolated struct MCPToolInfo: Sendable {
    var name: String
    var description: String?
    var inputSchema: JSON?

    static func list(_ result: JSON) -> [MCPToolInfo] {
        (result["tools"]?.array ?? []).compactMap { t in
            guard let n = t["name"]?.string else { return nil }
            return MCPToolInfo(name: n, description: t["description"]?.string, inputSchema: t["inputSchema"])
        }
    }
}

enum MCPResultMapper {
    /// Maps a `tools/call` result's content blocks into a ToolResult (text joined, first image attached).
    static func toolResult(_ result: JSON) -> ToolResult {
        var texts: [String] = []
        var image: (Data, String)?
        for block in result["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "text": if let t = block["text"]?.string { texts.append(t) }
            case "image":
                if image == nil, let b = block["data"]?.string, let d = Data(base64Encoded: b) { image = (d, block["mimeType"]?.string ?? "image/png") }
                texts.append("[image]")
            case "resource":
                let r = block["resource"]
                texts.append(r?["text"]?.string ?? "[resource \(r?["uri"]?.string ?? "")]")
            case "resource_link": texts.append("[resource \(block["uri"]?.string ?? "")]")
            default: break
            }
        }
        if texts.isEmpty, let s = result["structuredContent"], s != .null { texts.append(s.compact) }
        let isError = result["isError"]?.bool ?? false
        let out = texts.isEmpty ? (isError ? "error" : "done (no output)") : texts.joined(separator: "\n")
        var r = isError ? ToolResult.fail(out) : ToolResult.ok(out)
        r.image = image
        return r
    }
}

// MARK: Manager

@Observable
final class MCPManager {
    static let shared = MCPManager()

    enum State: Equatable {
        case connecting, connected(tools: Int), failed(String), disabled
        var label: String {
            switch self {
            case .connecting: return "connecting"
            case .connected(let n): return "connected, \(n) tool\(n == 1 ? "" : "s")"
            case .failed(let m): return m
            case .disabled: return "disabled"
            }
        }
    }

    struct Server: Identifiable, Equatable {
        var name: String
        var command: String
        var state: State
        var source = "Anvil"
        var id: String { name }
    }

    /// Where servers come from, highest priority first (a name defined earlier wins).
    static func sources(project: URL?) -> [(label: String, url: URL, key: String?)] {
        let home = Paths.home
        var out: [(String, URL, String?)] = [("Anvil", MCPServerConfig.fileURL, nil)]
        if let project { out.append(("project .mcp.json", project.appendingPathComponent(".mcp.json"), nil)) }
        out.append(("Peep", home.appendingPathComponent("Library/Application Support/Peep/mcp.json"), nil))
        out.append(("Claude Desktop", home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"), nil))
        out.append(("Claude Code", home.appendingPathComponent(".claude.json"), project?.path))
        return out
    }

    /// Reads every source and merges them. Claude Code's ~/.claude.json also has per-project servers.
    static func loadConfigs(project: URL?) -> (configs: [(MCPServerConfig, String)], errors: [String]) {
        var seen = Set<String>()
        var out: [(MCPServerConfig, String)] = []
        var errors: [String] = []
        for (label, url, projectKey) in sources(project: project) where FileManager.default.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var texts = [text]
            if let projectKey, let j = JSON.parse(text), let per = j["projects"]?[projectKey]?["mcpServers"] {
                texts.append(JSON.object(["mcpServers": per]).compact)
            }
            for t in texts {
                do {
                    for c in try MCPServerConfig.parse(t) where seen.insert(c.name).inserted { out.append((c, label)) }
                } catch {
                    if label == "Anvil" || label.hasPrefix("project") { errors.append("\(label): \(error.localizedDescription)") }
                }
            }
        }
        return (out, errors)
    }

    private(set) var servers: [Server] = []
    private(set) var configError: String?
    /// Bumped whenever the set of MCP tools changes (agents pick up new tools on their next step).
    private(set) var toolsVersion = 0
    @ObservationIgnored private(set) var toolSpecs: [ToolSpec] = []
    @ObservationIgnored private var clients: [String: MCPStdioClient] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var projectRoot: URL?

    static let connectTimeout: Double = 45
    static let callTimeout: Double = 120

    /// Reads the global and project configs and connects every server in the background.
    func start(project: URL?) {
        stopAll()
        self.projectRoot = project
        generation += 1
        let gen = generation
        configError = nil
        let loaded = Self.loadConfigs(project: project)
        let configs = loaded.0.map(\.0)
        configError = loaded.1.isEmpty ? nil : loaded.1.joined(separator: "; ")
        servers = loaded.0.map { c, source in
            let state: State = c.disabled ? .disabled : c.command == nil ? .failed(c.url != nil ? "HTTP servers aren't supported yet (use npx mcp-remote <url>)" : "no command") : .connecting
            return Server(name: c.name, command: ([c.command ?? c.url ?? ""] + c.args).joined(separator: " "), state: state, source: source)
        }
        for c in configs where !c.disabled && c.command != nil {
            Task { [weak self] in await self?.connect(c, gen: gen) }
        }
    }

    func stopAll() {
        for c in clients.values { c.stop() }
        clients = [:]
        toolSpecs = []
    }

    func openConfig() {
        let url = MCPServerConfig.fileURL
        if !FileManager.default.fileExists(atPath: url.path) { try? MCPServerConfig.template.write(to: url, atomically: true, encoding: .utf8) }
#if canImport(AppKit)
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
#else
        // TODO(linux): no NSWorkspace to open the file in an editor; the template is still written above.
#endif
    }

    var statusLines: [String] {
        if servers.isEmpty { return ["No MCP servers configured. Add them to \(MCPServerConfig.fileURL.path), the project's .mcp.json, Peep, Claude Desktop or Claude Code."] + (configError.map { [$0] } ?? []) }
        return servers.map { "\($0.name) [\($0.source)]: \($0.state.label)" }
    }

    /// Waits until no server is still connecting (or the timeout passes).
    func waitUntilSettled(timeout: Double = Double(MCPManager.connectTimeout) + 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, servers.contains(where: { $0.state == .connecting }) {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    var project: URL? { projectRoot }

    private func connect(_ config: MCPServerConfig, gen: Int) async {
        let client = MCPStdioClient(config: config)
        do {
            try client.start()
            clients[config.name] = client
            let tools = try await Self.handshake(client)
            guard gen == generation else { client.stop(); return }
            let specs = tools.map { Self.spec(server: config.name, tool: $0, client: client) }
            toolSpecs.removeAll { $0.name.hasPrefix(MCPSchema.toolName(server: config.name, tool: "")) }
            toolSpecs += specs
            toolsVersion += 1
            setState(config.name, .connected(tools: specs.count))
        } catch {
            client.stop()
            guard gen == generation else { return }
            clients[config.name] = nil
            var msg = error.localizedDescription
            if case MCPError.timeout = error, let tail = client.lastStderr.split(separator: "\n").last { msg += ": \(tail)" }
            setState(config.name, .failed(Fmt.line(msg, 160)))
        }
    }

    static func handshake(_ client: MCPStdioClient) async throws -> [MCPToolInfo] {
        _ = try await client.request("initialize", .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string(AppInfo.name), "version": .string(AppInfo.version)]),
        ]), timeout: connectTimeout)
        client.notify("notifications/initialized")
        var tools: [MCPToolInfo] = []
        var cursor: String?
        repeat {
            let r = try await client.request("tools/list", cursor.map { .object(["cursor": .string($0)]) }, timeout: 20)
            tools += MCPToolInfo.list(r)
            cursor = r["nextCursor"]?.string
        } while cursor != nil && tools.count < 500
        return tools
    }

    private func setState(_ name: String, _ s: State) {
        if let i = servers.firstIndex(where: { $0.name == name }) { servers[i].state = s }
    }

    static func spec(server: String, tool: MCPToolInfo, client: MCPStdioClient) -> ToolSpec {
        let mcpName = tool.name
        return ToolSpec(name: MCPSchema.toolName(server: server, tool: tool.name), kind: .exec,
                        signature: MCPSchema.signature(tool.inputSchema),
                        summary: MCPSchema.summary(tool.description), group: .mcp) { args, _ in
            guard !client.exited else { return .fail("the \(server) MCP server isn't running") }
            let r = try await client.request("tools/call", .object(["name": .string(mcpName), "arguments": args]), timeout: callTimeout)
            return MCPResultMapper.toolResult(r)
        }
    }
}


/// Reads and writes Anvil's mcp.json (Claude's format), keeping any other keys intact.
enum MCPConfigFile {
    private static func read() throws -> [String: Any] {
        let url = MCPServerConfig.fileURL
        guard let data = FileManager.default.contents(atPath: url.path), !data.isEmpty else { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPError.badConfig("mcp.json isn't a JSON object") }
        return obj
    }

    private static func write(_ obj: [String: Any]) throws {
        let url = MCPServerConfig.fileURL
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func upsert(name: String, command: String, args: [String], env: [String: String]) throws {
        var root = try read()
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        var entry: [String: Any] = ["command": command, "args": args]
        if !env.isEmpty { entry["env"] = env }
        servers[name] = entry
        root["mcpServers"] = servers
        try write(root)
    }

    static func remove(name: String) throws -> Bool {
        var root = try read()
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        guard servers.removeValue(forKey: name) != nil else { return false }
        root["mcpServers"] = servers
        try write(root)
        return true
    }
}
