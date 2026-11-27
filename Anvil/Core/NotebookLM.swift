import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Refuses automatic redirects, so the client follows every hop itself and keeps the cookies each one sets.
nonisolated final class NotebookRedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// NotebookLM's web API, reached with a signed-in Google account the way the browser reaches it: redirects are
/// followed by hand, the SetOSID sign-in hand-off form is posted, and the NotebookLM host that serves the app
/// (notebook.google.com after a redirect) is used for every later call. The RPC ids rotate, so each one can be
/// overridden by Paths.support/notebooklm-rpc.json.
nonisolated final class NotebookLMClient: @unchecked Sendable {
    struct Notebook: Equatable, Sendable {
        var id: String
        var title: String
        var sourceCount: Int
    }

    struct Source: Equatable, Sendable {
        var id: String
        var title: String
    }

    struct Tokens: Equatable, Sendable {
        var at: String
        var fsid: String
        var bl: String
    }

    /// The batchexecute ids, one per call.
    struct RPC: Sendable {
        var list = "wXbhsf"
        var create = "CCqFvf"
        var addText = "izAoDd"
        var getNotebook = "rLM1Ne"
        var deleteSource = "tGMBJ"

        static func load() -> RPC {
            var rpc = RPC()
            let file = Paths.support.appendingPathComponent("notebooklm-rpc.json")
            guard let data = try? Data(contentsOf: file), let json = JSON.parse(String(decoding: data, as: UTF8.self)) else { return rpc }
            rpc.list = json["list"]?.string ?? rpc.list
            rpc.create = json["create"]?.string ?? rpc.create
            rpc.addText = json["addText"]?.string ?? rpc.addText
            rpc.getNotebook = json["getNotebook"]?.string ?? rpc.getNotebook
            rpc.deleteSource = json["deleteSource"]?.string ?? rpc.deleteSource
            return rpc
        }
    }

    /// Free accounts allow 50 sources per notebook; the eviction limit is the plan's sources minus five.
    static let sourceLimit = 45
    /// The most text one source takes here (NotebookLM's own limit is larger; this keeps requests modest).
    static let maxSourceChars = 400_000
    static let notebookHosts = ["notebooklm.google.com", "notebook.google.com"]
    static let streamPath = "_/LabsTailwindUi/data/google.internal.labs.tailwind.orchestration.v1.LabsTailwindOrchestrationService/GenerateFreeFormStreamed"

    /// The account's Google cookies, sent to every host.
    private let baseCookies: [String: String]
    /// Cookies each host set on this client. Set-Cookie values never change the base cookies.
    private var hostCookies: [String: [String: String]] = [:]
    private let authUser: Int?
    private let session: URLSession
    private let rpc = RPC.load()
    private var tokens: Tokens?
    /// The NotebookLM host that answered with the app page.
    private var appHost = "notebooklm.google.com"
    private var reqCounter = Int.random(in: 100_000...899_999)

    /// `authUser` is Google's account index (`authuser=`) when several accounts are signed in; nil for the default.
    init(cookies: [String: String], authUser: Int? = nil) {
        baseCookies = cookies
        self.authUser = authUser
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpAdditionalHeaders = ["User-Agent": GeminiWebClient.userAgent]
        session = URLSession(configuration: cfg, delegate: NotebookRedirectRefuser(), delegateQueue: nil)
    }

    /// The account cookies this client was made with (a changed sign-in makes a new client).
    var accountCookies: [String: String] { baseCookies }

    // MARK: Notebooks and sources

    func listNotebooks() async throws -> [Notebook] {
        let r = try await call(rpc.list, .array([.null, Self.num(1), .null, .array([Self.num(2)])]))
        return Self.parseNotebooks(r ?? .array([]))
    }

    func createNotebook(title: String) async throws -> String {
        let r = try await call(rpc.create, .array([.string(title), .null, .null, .array([Self.num(2)]), Self.settings([1])]))
        guard let id = r?[2]?.string, !id.isEmpty else { throw BrainError(status: 0, code: "upstream_error", message: "NotebookLM didn't create the notebook.") }
        return id
    }

    /// Adds `text` as a pasted-text source and returns the new source's id.
    func addTextSource(notebook: String, title: String, text: String) async throws -> String {
        var fields: [JSON] = [.null, .array([.string(title), .string(text)]), .null, Self.num(2)]
        fields += Array(repeating: JSON.null, count: 6)
        fields.append(Self.num(1))
        let params = JSON.array([.array([.array(fields)]), .string(notebook), .array([Self.num(2)]), Self.settings([1])])
        let r = try await call(rpc.addText, params, sourcePath: "/notebook/\(notebook)")
        guard let id = r?[0]?[0]?[0]?.string, !id.isEmpty else { throw BrainError(status: 0, code: "upstream_error", message: "NotebookLM didn't add the source.") }
        return id
    }

    func sources(notebook: String) async throws -> [Source] {
        let r = try await call(rpc.getNotebook, .array([.string(notebook), .null, .array([Self.num(2)]), .null, Self.num(0)]), sourcePath: "/notebook/\(notebook)")
        return Self.parseSources(r ?? .array([]))
    }

    func deleteSource(_ id: String) async throws {
        _ = try await call(rpc.deleteSource, .array([.array([.array([.string(id)])]), .array([Self.num(2)])]))
    }

    /// Asks the notebook a question over all of its current sources and returns the answer text.
    func ask(notebook: String, question: String) async throws -> String {
        let ids = try await sources(notebook: notebook).map(\.id)
        let body: String = try await authorized {
            let t = try current()
            let params = JSON.array([
                .array(ids.map { JSON.array([JSON.array([.string($0)])]) }),
                .string(question), .null,
                .array([Self.num(2), .null, .array([Self.num(1)]), Self.settings([1, 3])]),
                .string(UUID().uuidString.uppercased()), .null, .null,
                .string(notebook), Self.num(1),
            ])
            let freq = JSON.array([.null, .string(params.compact)]).compact
            let items = [URLQueryItem(name: "bl", value: t.bl), URLQueryItem(name: "hl", value: "en"),
                         URLQueryItem(name: "_reqid", value: nextReqID()), URLQueryItem(name: "rt", value: "c"),
                         URLQueryItem(name: "f.sid", value: t.fsid)]
            let req = post(try url(Self.streamPath, items), body: "f.req=\(Self.encode(freq))&at=\(Self.encode(t.at))&")
            let (data, _) = try await send(req)
            return String(decoding: data, as: UTF8.self)
        }
        if let text = Self.parseStreamAnswer(body) { return text }
        if let failure = Self.batchError(body) { throw failure }
        throw BrainError(status: 0, code: "upstream_error", message: "NotebookLM returned no answer.")
    }

    // MARK: Session

    /// Walks the sign-in hand-offs the way a browser does and keeps the NotebookLM host that serves the app.
    /// A sign-in page without the SetOSID hand-off form means the Google sign-in has lapsed.
    func establishSession() async throws {
        var url = try self.url("", [])
        var method = "GET"
        var body: Data?
        var headers: [String: String] = [:]
        for _ in 0..<14 {
            let (data, http) = try await raw(url, method: method, body: body, headers: headers)
            let status = http.statusCode
            if (300..<400).contains(status) {
                guard let location = http.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw BrainError(status: status, code: "upstream_error", message: "NotebookLM sent a redirect without a destination.")
                }
                url = next
                method = "GET"
                body = nil
                headers = [:]
                continue
            }
            guard status == 200 else {
                throw BrainError(status: status, code: status == 401 || status == 403 ? "unauthorized" : "upstream_error",
                                 message: status == 401 || status == 403 ? Self.signInMessage : "NotebookLM error \(status).")
            }
            let html = String(decoding: data, as: UTF8.self)
            let host = url.host ?? ""
            if host.hasPrefix("accounts.") {
                guard let form = Self.setOSIDForm(html) else { throw BrainError(status: 401, code: "unauthorized", message: Self.signInMessage) }
                url = form.action
                method = "POST"
                body = Data(Self.formBody(form.fields).utf8)
                headers = ["Content-Type": "application/x-www-form-urlencoded;charset=UTF-8", "Origin": "https://accounts.google.com"]
                continue
            }
            if Self.notebookHosts.contains(host), let t = Self.parseTokens(html) {
                tokens = t
                appHost = host
                return
            }
            if html.contains("landing-header-signin") { throw BrainError(status: 401, code: "unauthorized", message: Self.signInMessage) }
            throw BrainError(status: 0, code: "upstream_error", message: "Couldn't read NotebookLM's session tokens. Google may have changed its page.")
        }
        throw BrainError(status: 0, code: "upstream_error", message: "NotebookLM's sign-in took too many steps.")
    }

    private static let signInMessage = "Google wouldn't open NotebookLM with this account's saved sign-in."

    /// Runs one request on an established session. An "unauthorized" answer re-establishes the session once.
    private func authorized<T>(_ op: () async throws -> T) async throws -> T {
        if tokens == nil { try await establishSession() }
        do { return try await op() }
        catch let error as BrainError where error.code == "unauthorized" {
            tokens = nil
            try await establishSession()
            return try await op()
        }
    }

    private func current() throws -> Tokens {
        guard let tokens else { throw BrainError(status: 401, code: "unauthorized", message: Self.signInMessage) }
        return tokens
    }

    /// One batchexecute call. Nil when Google answered with a null result.
    private func call(_ id: String, _ params: JSON, sourcePath: String = "/") async throws -> JSON? {
        let body: String = try await authorized {
            let t = try current()
            let items = [URLQueryItem(name: "rpcids", value: id), URLQueryItem(name: "source-path", value: sourcePath),
                         URLQueryItem(name: "bl", value: t.bl), URLQueryItem(name: "hl", value: "en"),
                         URLQueryItem(name: "rt", value: "c"), URLQueryItem(name: "f.sid", value: t.fsid),
                         URLQueryItem(name: "_reqid", value: nextReqID())]
            var req = post(try url("_/LabsTailwindUi/data/batchexecute", items), body: Self.encodeBatch(rpc: id, params: params, at: t.at))
            req.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            let (data, _) = try await send(req)
            return String(decoding: data, as: UTF8.self)
        }
        if let failure = Self.batchError(body) { throw failure }
        return Self.parseBatch(body, rpc: id)
    }

    private func nextReqID() -> String {
        defer { reqCounter += 100_000 }
        return String(reqCounter)
    }

    private func url(_ path: String, _ query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(string: "https://\(appHost)/" + path) else { throw BrainError(status: 0, code: "network", message: "Bad NotebookLM URL") }
        var items = query
        if let authUser { items.append(URLQueryItem(name: "authuser", value: String(authUser))) }
        comps.queryItems = items.isEmpty ? nil : items
        guard let u = comps.url else { throw BrainError(status: 0, code: "network", message: "Bad NotebookLM URL") }
        return u
    }

    private func post(_ url: URL, body: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("https://\(appHost)", forHTTPHeaderField: "Origin")
        req.setValue("https://\(appHost)/", forHTTPHeaderField: "Referer")
        req.setValue("1", forHTTPHeaderField: "X-Same-Domain")
        req.httpBody = Data(body.utf8)
        return req
    }

    /// One request with no automatic redirects. The cookies the answer sets are kept for its host.
    private func raw(_ url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        let host = url.host ?? ""
        req.setValue(cookieHeader(for: host), forHTTPHeaderField: "Cookie")
        if headers["Accept"] == nil { req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BrainError(status: 0, code: "network", message: error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw BrainError(status: 0, code: "network", message: "No response from NotebookLM") }
        absorbCookies(http, host: host)
        return (data, http)
    }

    /// An authorized batch or stream request: the answer must be a 200.
    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var r = req
        r.setValue(cookieHeader(for: r.url?.host ?? ""), forHTTPHeaderField: "Cookie")
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: r) }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BrainError(status: 0, code: "network", message: error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw BrainError(status: 0, code: "network", message: "No response from NotebookLM") }
        absorbCookies(http, host: r.url?.host ?? "")
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 300..<400, 401, 403:
            throw BrainError(status: http.statusCode, code: "unauthorized", message: Self.signInMessage)
        case 429:
            throw BrainError(status: 429, code: "usage_limit", message: "NotebookLM is limiting this account for now. Free accounts get 50 questions a day.")
        default:
            throw BrainError(status: http.statusCode, code: "upstream_error", message: "NotebookLM error \(http.statusCode).")
        }
    }

    // MARK: Cookies

    /// The account cookies plus what this host set, as a Cookie header.
    private func cookieHeader(for host: String) -> String {
        var all = baseCookies
        for (name, value) in hostCookies[host] ?? [:] { all[name] = value }
        return all.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    private func absorbCookies(_ http: HTTPURLResponse, host: String) {
        for (key, value) in http.allHeaderFields {
            guard (key as? String)?.lowercased() == "set-cookie", let raw = value as? String else { continue }
            for cookie in Self.parseSetCookies(raw) {
                if cookie.value.isEmpty { hostCookies[host]?[cookie.name] = nil }
                else { hostCookies[host, default: [:]][cookie.name] = cookie.value }
            }
        }
    }

    /// Name and value of each cookie in a Set-Cookie header. Several may be joined with commas, and Expires has commas too.
    static func parseSetCookies(_ raw: String) -> [(name: String, value: String)] {
        guard let re = try? NSRegularExpression(pattern: #",\s*(?=[^;,=\s]+=)"#) else { return [] }
        let marked = re.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "\u{1}")
        return marked.components(separatedBy: "\u{1}").compactMap { chunk in
            let first = chunk.components(separatedBy: ";").first ?? ""
            guard let eq = first.firstIndex(of: "=") else { return nil }
            let name = first[..<eq].trimmingCharacters(in: .whitespaces)
            let value = first[first.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : (name: name, value: value)
        }
    }

    // MARK: Request encoding

    /// The form body for one batchexecute call: `f.req=[[[rpc, params-as-JSON-string, null, "generic"]]]&at=...&`.
    static func encodeBatch(rpc: String, params: JSON, at: String) -> String {
        let item = JSON.array([.string(rpc), .string(params.compact), .null, .string("generic")])
        let freq = JSON.array([.array([item])]).compact
        return "f.req=\(encode(freq))&at=\(encode(at))&"
    }

    /// The trailing settings block the web app sends: `[1, null x9, [flags]]`.
    private static func settings(_ flags: [Int]) -> JSON {
        var fields: [JSON] = [num(1)]
        fields += Array(repeating: JSON.null, count: 9)
        fields.append(.array(flags.map { num($0) }))
        return .array(fields)
    }

    private static func num(_ n: Int) -> JSON { .number(Double(n)) }

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    private static func formBody(_ fields: [String: String]) -> String {
        fields.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }

    // MARK: Response parsing

    /// The sign-in hand-off form (accounts/SetOSID): its action and every named input. Nil when the page has none.
    static func setOSIDForm(_ html: String) -> (action: URL, fields: [String: String])? {
        guard let formRe = try? NSRegularExpression(pattern: #"<form\b[^>]*?\baction\s*=\s*["']([^"']*SetOSID[^"']*)["'][^>]*>([\s\S]*?)</form>"#, options: [.caseInsensitive]),
              let m = formRe.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let actionRange = Range(m.range(at: 1), in: html), let bodyRange = Range(m.range(at: 2), in: html),
              let action = URL(string: unescapeHTML(String(html[actionRange]))) else { return nil }
        let body = String(html[bodyRange])
        var fields: [String: String] = [:]
        if let inputRe = try? NSRegularExpression(pattern: #"<input\b[^>]*>"#, options: [.caseInsensitive]) {
            for input in inputRe.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                let tag = NSString(string: body).substring(with: input.range)
                guard let name = attribute("name", in: tag) else { continue }
                fields[name] = attribute("value", in: tag) ?? ""
            }
        }
        return (action: action, fields: fields)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\w-])\#(name)\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive]),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag) else { return nil }
        return unescapeHTML(String(tag[r]))
    }

    /// Decodes the HTML entities a hand-off form uses. `&amp;` goes last so it is not decoded twice.
    static func unescapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The session tokens on the app page (`at` is required).
    static func parseTokens(_ html: String) -> Tokens? {
        guard let at = match(#""SNlM0e":\s*"([^"]+)""#, html) else { return nil }
        return Tokens(at: at, fsid: match(#""FdrFJe":\s*"([^"]+)""#, html) ?? "", bl: match(#""cfb2h":\s*"([^"]+)""#, html) ?? "")
    }

    /// The result of one RPC: item 2 of its `wrb.fr` frame, parsed. Nil when the frame is missing or null.
    static func parseBatch(_ body: String, rpc: String) -> JSON? {
        for frame in frames(body) where frame[0]?.string == "wrb.fr" && frame[1]?.string == rpc {
            if let raw = frame[2]?.string, let inner = JSON.parse(raw) { return inner }
        }
        return nil
    }

    /// The answer text of a streamed ask. Each chunk carries the answer so far, so the longest one wins.
    static func parseStreamAnswer(_ body: String) -> String? {
        var best: String?
        for frame in frames(body) where frame[0]?.string == "wrb.fr" {
            guard let raw = frame[2]?.string, let inner = JSON.parse(raw),
                  let text = inner[0]?[0]?.string, !text.isEmpty else { continue }
            if best == nil || text.count > best!.count { best = text }
        }
        return best
    }

    /// An `er` frame in a response, as an error (usage limits are recognised by their wording).
    static func batchError(_ body: String) -> BrainError? {
        guard let frame = frames(body).first(where: { $0[0]?.string == "er" }) else { return nil }
        if frame.compact.lowercased().contains("quota") || frame.compact.lowercased().contains("limit") {
            return BrainError(status: 429, code: "usage_limit", message: "NotebookLM's limit was reached. Free accounts get 50 questions a day.")
        }
        return BrainError(status: 0, code: "upstream_error", message: "NotebookLM returned an error (\(frame[5]?.int ?? 0)).")
    }

    /// Every frame in a batchexecute or streamed response. The `)]}'` header and the length lines are skipped.
    static func frames(_ body: String) -> [JSON] {
        var out: [JSON] = []
        for line in body.split(whereSeparator: { $0.isNewline }) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), let arr = JSON.parse(t)?.array else { continue }
            if arr.first?.array != nil { out.append(contentsOf: arr) } else { out.append(.array(arr)) }
        }
        return out
    }

    /// Notebooks from a list result. Some versions wrap the list one level deeper, so both shapes are accepted.
    static func parseNotebooks(_ result: JSON) -> [Notebook] {
        func isNotebook(_ j: JSON) -> Bool { j.array != nil && j[0]?.string != nil && j[2]?.string?.isEmpty == false }
        let list: [JSON]
        if let a = result.array, a.contains(where: isNotebook) { list = a }
        else if let a = result[0]?.array, a.contains(where: isNotebook) { list = a }
        else { return [] }
        return list.compactMap { nb in
            guard isNotebook(nb), let id = nb[2]?.string else { return nil }
            return Notebook(id: id, title: nb[0]?.string ?? "", sourceCount: nb[1]?.array?.count ?? 0)
        }
    }

    /// Sources from a notebook result: every `[["uuid"], "title", ...]` shape, in order, without repeats.
    /// Numbers and other metadata never match: the id must be a string holding a UUID.
    static func parseSources(_ result: JSON) -> [Source] {
        var out: [Source] = []
        var seen = Set<String>()
        func walk(_ j: JSON) {
            guard case .array(let items) = j else { return }
            if items.count > 1, case .array(let idCell) = items[0], idCell.count == 1,
               case .string(let id) = idCell[0], UUID(uuidString: id) != nil,
               case .string(let title) = items[1], seen.insert(id).inserted {
                out.append(Source(id: id, title: title))
            }
            for item in items { walk(item) }
        }
        walk(result)
        return out
    }

    /// The sources to delete before one more is added, so the notebook stays under `keep`. Only our own uploads
    /// are candidates, oldest first.
    static func sourcesToEvict(count: Int, recorded: [String], keep: Int = sourceLimit) -> [String] {
        guard count >= keep else { return [] }
        return Array(recorded.prefix(count - keep + 1))
    }

    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
