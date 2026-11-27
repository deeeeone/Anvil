import Foundation

/// `anvil-provider.json`: everything Anvil needs to know to use a model provider it doesn't ship with.
///
/// Two kinds:
/// - `"openai"`: any OpenAI-compatible chat API. No code: a base URL, how to authenticate, and a few
///   capability flags.
/// - `"process"`: anything else (a website's private API, an unusual protocol). The plugin ships a command;
///   Anvil runs it and speaks a small JSON-lines protocol over stdin and stdout (see docs/PROVIDERS.md).
///
/// Models from a plugin are named `<id>/<model>` in Anvil (for example `zai/glm-4.6`), so they never collide
/// with built-in models or with other plugins.
nonisolated struct ProviderSpec: Codable, Equatable, Sendable {
    static let fileName = "anvil-provider.json"
    static let version = 1
    /// Built-in provider names a plugin can't take.
    static let reserved: Set<String> = ["anvil", "experiential", "luna", "gemini", "chatgpt", "builtin", "local"]

    enum Kind: String, Codable, Sendable { case openai, process }

    /// Spec version this file was written for (currently 1).
    var spec: Int
    /// Short, unique, lowercase: letters, digits and dashes. Prefixes the provider's model ids.
    var id: String
    var name: String
    var description: String?
    /// An SF Symbol name for menus (default "cpu").
    var symbol: String?
    var homepage: String?
    var type: Kind

    // "openai"
    /// The API root that "chat/completions" hangs off, like OpenAI SDKs' base URL (e.g. https://api.z.ai/api/paas/v4).
    var baseURL: String?
    /// Relative to baseURL. Default "chat/completions".
    var chatPath: String?
    /// Relative to baseURL. Default "models"; "" turns live model listing off.
    var modelsPath: String?
    /// Extra headers sent with every request.
    var headers: [String: String]?
    /// Extra fields merged into every chat request body (e.g. {"enable_thinking": false}).
    var body: JSON?
    /// Settings shows a URL field so users can point the plugin at their own deployment (self-hosted proxies).
    var editableBaseURL: Bool?
    /// A local server Anvil runs for this plugin (an "openai" plugin whose API is a program on this Mac).
    var server: Server?

    // "process"
    /// Run from the plugin's folder, e.g. ["python3", "provider.py"] or ["node", "index.js"].
    var command: [String]?

    var auth: Auth
    /// Models to offer before (or instead of) live listing.
    var models: [Model]?
    var capabilities: Capabilities?
    /// The provider costs nothing to use (shown as "free"; usage is still counted).
    var free: Bool?

    nonisolated struct Auth: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case none, apiKey, web }
        var type: Kind
        // apiKey
        /// Header for the key. Default "Authorization".
        var header: String?
        /// Text before the key in that header. Default "Bearer " for Authorization, "" otherwise.
        var prefix: String?
        /// Label for the key field in Settings (default "API key").
        var label: String?
        /// Where to get a key (shown as a link).
        var keyURL: String?
        /// The key may be left empty (servers where a key is only needed when the owner set one).
        var optional: Bool?
        // web
        /// The page to sign in on.
        var loginURL: String?
        /// Only cookies for this domain (and its subdomains) are captured, e.g. "z.ai".
        var domain: String?
        /// Signed in = all of these cookies exist.
        var cookies: [String]?
        /// localStorage keys to capture after sign-in (e.g. ["token"]).
        var localStorage: [String]?
        /// For "openai" plugins with web sign-in: where the bearer token comes from, "localStorage:token" or "cookie:name".
        var bearer: String?
        /// Don't save automatically when the values first exist (guest tokens exist before signing in); wait for the owner.
        var manual: Bool?
    }

    /// A program that serves the plugin's API on this Mac. Anvil runs `setup` once (and again when the
    /// plugin changes), starts `command` the first time the provider is used, waits until `ready` answers,
    /// and stops it when Anvil quits. Both run from the plugin's folder.
    nonisolated struct Server: Codable, Equatable, Sendable {
        /// Installs dependencies, e.g. ["sh", "setup.sh"]. Optional.
        var setup: [String]?
        /// Starts the server and keeps running, e.g. ["sh", "start.sh"].
        var command: [String]
        /// Extra environment variables for both.
        var env: [String: String]?
        /// A local URL that answers once the server is up (any HTTP response below 500 counts).
        var ready: String
        /// Seconds to wait for `ready` (default 90).
        var startupTimeout: Double?
        /// Seconds `setup` may take (default 900).
        var setupTimeout: Double?
    }

    nonisolated struct Model: Codable, Equatable, Sendable {
        var id: String
        var name: String?
        /// The model reads images itself.
        var vision: Bool?
        /// Context window in tokens.
        var context: Int?
        /// USD per million tokens.
        var input: Double?
        var output: Double?
    }

    nonisolated struct Capabilities: Codable, Equatable, Sendable {
        /// Honors `stop` sequences (default true). When false, Anvil ends the stream itself once the reply's JSON block closes.
        var stop: Bool?
        /// Accepts `reasoning_effort` (default false).
        var reasoningEffort: Bool?
        /// Streams with server-sent events (default true).
        var streaming: Bool?
        /// Sends usage in the last stream chunk when asked with stream_options (default true).
        var streamUsage: Bool?
        /// Name of the max-tokens field (default "max_tokens"; OpenAI's newer models want "max_completion_tokens").
        var maxTokensField: String?
    }

    // MARK: Derived

    var symbolName: String { symbol?.isEmpty == false ? symbol! : "cpu" }
    var honorsStop: Bool { capabilities?.stop ?? true }
    var streams: Bool { capabilities?.streaming ?? true }

    /// The OpenAI client endpoint for an "openai" plugin.
    func endpoint() -> OpenAIClient.Endpoint {
        var e = OpenAIClient.Endpoint()
        e.chatPath = (chatPath?.isEmpty == false ? chatPath! : "chat/completions").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let header = auth.header?.isEmpty == false ? auth.header! : "Authorization"
        e.authHeader = header
        e.authPrefix = auth.prefix ?? (header.lowercased() == "authorization" ? "Bearer " : "")
        e.headers = headers ?? [:]
        e.maxTokensField = capabilities?.maxTokensField ?? "max_tokens"
        e.sendsStop = honorsStop
        e.sendsEffort = capabilities?.reasoningEffort ?? false
        e.streamUsage = capabilities?.streamUsage ?? true
        if case .object(let o)? = body { e.extraBody = o }
        return e
    }

    // MARK: Validation

    /// Everything wrong with this spec, in words a plugin author can act on. Empty = valid.
    func problems() -> [String] {
        var out: [String] = []
        if spec > Self.version { out.append("written for spec \(spec); this Anvil understands up to \(Self.version). Update Anvil.") }
        if id.range(of: #"^[a-z0-9][a-z0-9-]{1,31}$"#, options: .regularExpression) == nil {
            out.append("id \"\(id)\" must be 2-32 lowercase letters, digits or dashes")
        }
        if Self.reserved.contains(id) { out.append("id \"\(id)\" is reserved for a built-in provider") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("name is empty") }
        switch type {
        case .openai:
            if let b = baseURL, let u = URL(string: b), let scheme = u.scheme?.lowercased(), u.host != nil {
                let local = ["localhost", "127.0.0.1", "::1"].contains(u.host!.lowercased()) || u.host!.hasSuffix(".local")
                if scheme != "https" && !(scheme == "http" && local) { out.append("baseURL must be https (http is only allowed for localhost)") }
            } else {
                out.append("an \"openai\" provider needs a baseURL like https://api.example.com/v1")
            }
            if command != nil { out.append("\"command\" is only for \"process\" providers") }
            if let b = body, b.object == nil { out.append("\"body\" must be an object of extra request fields") }
            if let srv = server {
                if srv.command.first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { out.append("server.command is empty") }
                if let host = URL(string: srv.ready)?.host?.lowercased(), ["localhost", "127.0.0.1", "::1"].contains(host) {} else {
                    out.append("server.ready must be a localhost URL, e.g. http://127.0.0.1:9876/v1/models")
                }
                if let b = baseURL, let host = URL(string: b)?.host?.lowercased(), !["localhost", "127.0.0.1", "::1"].contains(host) {
                    out.append("a plugin with a local server needs a localhost baseURL")
                }
            }
        case .process:
            if server != nil { out.append("\"server\" is only for \"openai\" providers (a process plugin is already a program)") }
            if (command ?? []).first?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { out.append("a \"process\" provider needs a command, e.g. [\"python3\", \"provider.py\"]") }
        }
        switch auth.type {
        case .none: break
        case .apiKey: break
        case .web:
            if URL(string: auth.loginURL ?? "")?.host == nil { out.append("web sign-in needs auth.loginURL") }
            if (auth.domain ?? "").isEmpty { out.append("web sign-in needs auth.domain (whose cookies to capture)") }
            if (auth.cookies ?? []).isEmpty && (auth.localStorage ?? []).isEmpty {
                out.append("web sign-in needs auth.cookies or auth.localStorage, so Anvil knows when you're signed in")
            }
            if type == .openai, let b = auth.bearer, !(b.hasPrefix("localStorage:") || b.hasPrefix("cookie:")) {
                out.append("auth.bearer must look like \"localStorage:token\" or \"cookie:name\"")
            }
        }
        if type == .openai, (models ?? []).isEmpty, modelsPath == "" { out.append("list models statically (\"models\") or allow live listing (\"modelsPath\")") }
        for m in models ?? [] where m.id.isEmpty || m.id.contains(" ") { out.append("model id \"\(m.id)\" can't be empty or contain spaces") }
        return out
    }

    /// https anywhere, or http on this Mac (localhost) only.
    static func isAllowedBaseURL(_ raw: String) -> Bool {
        guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased() else { return false }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".local")
        return scheme == "https" || (scheme == "http" && local)
    }

    static func load(_ url: URL) throws -> ProviderSpec {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ToolFailure("no \(fileName) at \(url.deletingLastPathComponent().path)") }
        return try load(data: data)
    }

    /// Decodes a spec from JSON bytes, with the same error messages as `load(_:)`.
    static func load(data: Data) throws -> ProviderSpec {
        do { return try JSONDecoder().decode(ProviderSpec.self, from: data) }
        catch let DecodingError.keyNotFound(key, ctx) { throw ToolFailure("\(fileName): missing \"\(([key] + ctx.codingPath.reversed()).reversed().map(\.stringValue).joined(separator: "."))\"") }
        catch let DecodingError.typeMismatch(_, ctx) { throw ToolFailure("\(fileName): wrong type at \"\(ctx.codingPath.map(\.stringValue).joined(separator: "."))\"") }
        catch let DecodingError.dataCorrupted(ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw ToolFailure("\(fileName): \(path.isEmpty ? "not valid JSON" : "bad value at \"\(path)\"")")
        }
        catch { throw ToolFailure("\(fileName): \(error.localizedDescription)") }
    }
}

/// `github.com/owner/repo`, optionally `/tree/<ref>/<folder>`, as a place to fetch a plugin from.
nonisolated struct GitHubSource: Equatable, Sendable {
    var owner: String
    var repo: String
    var ref: String?
    var path: String?

    var cloneURL: String { "https://github.com/\(owner)/\(repo).git" }
    var display: String { "github.com/\(owner)/\(repo)" + (ref.map { "@\($0)" } ?? "") + (path.map { "/\($0)" } ?? "") }

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://", "http://", "www."] where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        guard s.lowercased().hasPrefix("github.com/") else { return nil }
        let parts = s.dropFirst("github.com/".count).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        owner = parts[0]
        repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let ok = #"^[A-Za-z0-9_.-]+$"#
        guard owner.range(of: ok, options: .regularExpression) != nil, repo.range(of: ok, options: .regularExpression) != nil else { return nil }
        if parts.count >= 4, parts[2] == "tree" || parts[2] == "blob" {
            ref = parts[3]
            let rest = parts.dropFirst(4).filter { $0 != ProviderSpec.fileName }
            path = rest.isEmpty ? nil : rest.joined(separator: "/")
        }
        if let p = path, p.contains("..") { return nil }
        if let r = ref, r.range(of: #"^[A-Za-z0-9_./-]+$"#, options: .regularExpression) == nil || r.hasPrefix("-") { return nil }
    }
}
