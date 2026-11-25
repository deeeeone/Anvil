import Foundation

/// Gemini's own web endpoint (the protocol used by HanaokaYuzu/Gemini-API), implemented here.
/// One instance belongs to one account; cookies are merged back as Google rotates them.
nonisolated final class GeminiWebClient: @unchecked Sendable {
    let accountID: UUID
    private let jar: CookieJar
    private let session: URLSession
    private var accessToken = ""
    private var buildLabel = ""
    private var sessionID = UUID().uuidString.uppercased()
    private var language = "en"
    private var pushID = "feeds/mcudyrk2a4khkz"
    private var lastRotation = Date.distantPast
    /// The signed-in Google address, read from the app shell (empty if Google stops embedding it).
    private(set) var email = ""
    /// Which signed-in Google account in the browser to talk as (`authuser`). Nil uses the browser's first.
    let authUser: Int?

    static let base = URL(string: "https://gemini.google.com")!
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"

    /// The cookie jar after any rotations (for saving a validated account).
    var currentCookies: [String: String] { jar.snapshot }

    init(accountID: UUID, cookies: [String: String], authUser: Int? = nil) {
        self.accountID = accountID
        self.authUser = authUser
        jar = CookieJar(accountID: accountID, cookies: cookies)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 900
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: cfg)
    }

    /// Loads the app shell and the tokens it carries. Throws when the cookies aren't signed in.
    @discardableResult
    func prepare() async throws -> String {
        let app = authUser.map { URL(string: "https://gemini.google.com/u/\($0)/app")! } ?? Self.base.appendingPathComponent("app")
        var req = URLRequest(url: app)
        decorate(&req)
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, resp) = try await sendData(req)
        if let http = resp as? HTTPURLResponse { jar.merge(response: http, url: Self.base) }
        let html = String(decoding: data, as: UTF8.self)
        guard let token = Self.match(#""SNlM0e":\s*"(.*?)""#, html), !token.isEmpty else {
            throw BrainError(status: 401, code: "unauthorized", message: "Google didn't accept these cookies. Sign in again.")
        }
        accessToken = token
        buildLabel = Self.match(#""cfb2h":\s*"(.*?)""#, html) ?? ""
        sessionID = Self.match(#""FdrFJe":\s*"(.*?)""#, html) ?? UUID().uuidString.uppercased()
        language = Self.match(#""TuX5cc":\s*"(.*?)""#, html) ?? "en"
        pushID = Self.match(#""qKIAYe":\s*"(.*?)""#, html) ?? pushID
        email = Self.match(#""oPEP7c":\s*"([^"@\s]+@[^"\s]+)""#, html) ?? ""
        return token
    }

    /// Confirms the cookies are signed in and returns the Google address (empty when unknown).
    func identity() async throws -> String {
        try await prepare()
        return email
    }

    // MARK: Chat

    func chat(_ prompt: String, images: [(Data, String)] = [], model: String, onText: ((String) -> Void)?, shouldStop: ((String) -> Bool)?) async throws -> String {
        if accessToken.isEmpty { try await prepare() }
        await rotateIfNeeded()

        var fileData: [Any]?
        if !images.isEmpty {
            var uploaded: [[Any]] = []
            for (data, mime) in images {
                let file = try await upload(data, mime: mime)
                uploaded.append([[file.url], file.name])
            }
            fileData = uploaded
        }

        let reqID = Int.random(in: 100_000...999_999)
        let uuid = UUID().uuidString.uppercased()
        var inner = [Any](repeating: NSNull(), count: 81)
        inner[0] = [prompt, 0, NSNull(), fileData ?? [], NSNull(), NSNull(), 0]
        inner[1] = [language]
        inner[2] = ["", "", "", NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), ""]
        inner[6] = [1]
        inner[7] = 1
        inner[10] = 1
        inner[11] = 0
        inner[17] = [[0]]
        inner[18] = 0
        inner[27] = 1
        inner[30] = [4]
        inner[41] = [1]
        inner[45] = 1
        inner[53] = 0
        inner[59] = uuid
        inner[61] = []
        inner[68] = 1
        inner[79] = 1
        inner[80] = model.lowercased().contains("thinking") ? 2 : 1

        var modelHeaders: [String: String] = [:]
        if let header = Self.modelHeader(model) {
            inner[79] = header.number
            modelHeaders["x-goog-ext-525001261-jspb"] = header.value + ",1,\"\(sessionID)\""
        }

        let innerData = try JSONSerialization.data(withJSONObject: inner)
        let innerString = String(decoding: innerData, as: UTF8.self)
        let freq = try JSONSerialization.data(withJSONObject: [NSNull(), innerString])
        let freqString = String(decoding: freq, as: UTF8.self)

        var comps = URLComponents(url: Self.base.appendingPathComponent("_/BardChatUi/data/assistant.lamda.BardFrontendService/StreamGenerate"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "hl", value: language), URLQueryItem(name: "_reqid", value: String(reqID)), URLQueryItem(name: "rt", value: "c")]
        if !buildLabel.isEmpty { items.append(URLQueryItem(name: "bl", value: buildLabel)) }
        if !sessionID.isEmpty { items.append(URLQueryItem(name: "f.sid", value: sessionID)) }
        if let authUser { items.append(URLQueryItem(name: "authuser", value: String(authUser))) }
        comps.queryItems = items
        guard let url = comps.url else { throw BrainError(status: 0, code: "network", message: "Bad Gemini URL") }

        var req = URLRequest(url: url)
        decorate(&req)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "X-Same-Domain")
        req.setValue("[\"\(uuid)\",1]", forHTTPHeaderField: "x-goog-ext-525005358-jspb")
        for (k, v) in modelHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = Data("at=\(Self.encode(accessToken))&f.req=\(Self.encode(freqString))".utf8)

        var bytes: URLSession.AsyncBytes
        var resp: URLResponse
        do { (bytes, resp) = try await session.bytes(for: req) }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BrainError(status: 0, code: "network", message: error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw BrainError(status: 0, code: "network", message: "No response from Gemini") }
        jar.merge(response: http, url: Self.base)
        guard http.statusCode == 200 else {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 4000 { break } }
            let unauthorized = http.statusCode == 401 || http.statusCode == 403
            let code = unauthorized ? "unauthorized" : http.statusCode == 429 ? "usage_limit" : "upstream_error"
            throw BrainError(status: http.statusCode, code: code,
                             message: Fmt.line(String(decoding: data, as: UTF8.self), 300))
        }

        var full = ""
        var last: [Int: String] = [:]
        var fatal: BrainError?
        var lines = 0
        for try await line in bytes.lines {
            lines += 1
            if lines % 30 == 0, shouldStop?(full) == true { break }
            var body = line
            if body.hasPrefix(")]}'") { continue }
            guard body.hasPrefix("[") else { continue }
            guard let frames = JSON.parse(body)?.array else { continue }
            for frame in frames where frame.array?.first?.string == "wrb.fr" {
                guard let raw = frame.array?[safe: 2]?.string, let innerJSON = JSON.parse(raw) else { continue }
                if let code = innerJSON[5]?[2]?[0]?[1]?[0]?.int {
                    fatal = BrainError(status: 0, code: code == 7 ? "unauthorized" : code == 1 ? "usage_limit" : "upstream_error",
                                       message: Self.errorText(code))
                }
                guard let candidates = innerJSON[4]?.array else { continue }
                for (i, candidate) in candidates.enumerated() {
                    guard let text = candidate[1]?[0]?.string else { continue }
                    let previous = last[i] ?? ""
                    let delta = text.hasPrefix(previous) ? String(text.dropFirst(previous.count)) : text
                    last[i] = text
                    if delta.isEmpty { continue }
                    full = text
                    onText?(full)
                }
            }
        }
        if let fatal { throw fatal }
        if full.isEmpty {
            throw BrainError(status: 0, code: "upstream_error", message: "Gemini returned an empty reply. Try again, or add another account.")
        }
        if Self.isUsageLimitText(full) {
            throw BrainError(status: 0, code: "usage_limit", message: "Gemini usage limit reached for this account. Try another account or model.")
        }
        if Self.isServiceError(full) {
            throw BrainError(status: 0, code: "gemini_error", message: "Gemini answered with its own error (\"\(Fmt.line(full, 80))\"), usually because the message was too long for it.")
        }
        return full
    }

    /// A short reply that says the account hit its usage limit (wording varies, so match the common phrases).
    static func isUsageLimitText(_ reply: String) -> Bool {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard t.count < 300, !t.contains("```") else { return false }
        return ["usage limit", "reached your limit", "reached the limit", "hit your limit", "too many requests"].contains { t.contains($0) }
    }

    /// Gemini's web app answers some failures (most often a message too long for it) with a canned sentence
    /// instead of an error. That text must never be taken for the model's reply.
    static func isServiceError(_ reply: String) -> Bool {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard t.count < 300, !t.contains("```") else { return false }
        let canned = ["sorry, something went wrong", "something went wrong. please try", "i'm having a hard time fulfilling your request",
                      "i'm unable to process this request right now", "an error occurred. please try again"]
        return canned.contains { t.hasPrefix($0) || t.contains($0) }
    }

    private struct Uploaded {
        let url: String
        let name: String
    }

    /// Uploads one pasted image to Google's push endpoint and returns the reference the prompt uses.
    private func upload(_ data: Data, mime: String) async throws -> Uploaded {
        let ext: String
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "image/heic": ext = "heic"
        default: ext = "png"
        }
        let name = "input_\(Int.random(in: 1_000_000...9_999_999)).\(ext)"
        let boundary = "----Anvil" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: URL(string: "https://content-push.googleapis.com/upload")!)
        req.httpMethod = "POST"
        req.setValue(jar.header, forHTTPHeaderField: "Cookie")
        req.setValue("https://gemini.google.com/", forHTTPHeaderField: "Referer")
        req.setValue("bard-storage", forHTTPHeaderField: "X-Tenant-Id")
        req.setValue(pushID, forHTTPHeaderField: "Push-ID")
        if let authUser { req.setValue(String(authUser), forHTTPHeaderField: "X-Goog-AuthUser") }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (response, resp) = try await sendData(req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw BrainError(status: status, code: status == 401 || status == 403 ? "unauthorized" : "upstream_error",
                             message: "Gemini couldn't take the image. \(Fmt.line(String(decoding: response, as: UTF8.self), 160))")
        }
        let url = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { throw BrainError(status: 0, code: "upstream_error", message: "Gemini returned no image reference.") }
        return Uploaded(url: url, name: name)
    }

    private func rotateIfNeeded() async {
        guard Date().timeIntervalSince(lastRotation) > 600 else { return }
        lastRotation = Date()
        var req = URLRequest(url: URL(string: "https://accounts.google.com/RotateCookies")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://accounts.google.com", forHTTPHeaderField: "Origin")
        req.setValue(jar.header, forHTTPHeaderField: "Cookie")
        req.httpBody = Data(#"[000,"-0000000000000000000"]"#.utf8)
        guard let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return }
        jar.merge(response: http, url: req.url!)
    }

    private func sendData(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw BrainError(status: 0, code: "network", message: error.localizedDescription)
        }
    }

    private func decorate(_ req: inout URLRequest) {
        req.setValue(jar.header, forHTTPHeaderField: "Cookie")
        req.setValue("https://gemini.google.com", forHTTPHeaderField: "Origin")
        req.setValue("https://gemini.google.com/", forHTTPHeaderField: "Referer")
        if let authUser { req.setValue(String(authUser), forHTTPHeaderField: "X-Goog-AuthUser") }
    }

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    private static func match(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func errorText(_ code: Int) -> String {
        switch code {
        case 1: return "Gemini usage limit reached for this account. Try another account or model."
        case 7: return "Google refused the request. The account cookies may have expired."
        case 1013: return "Gemini had a temporary error. Try again."
        default: return "Gemini error \(code)."
        }
    }

    private static func modelHeader(_ model: String) -> (value: String, number: Int)? {
        let m = model.lowercased()
        let id: String
        let number: Int
        if m.contains("lite") { id = "cf41b0e0dd7d53e5"; number = 6 }
        else if m.contains("flash") { id = "fbb127bbb056c959"; number = 1 }
        else if m.contains("pro") { id = "9d8ca3786ebdfbea"; number = 3 }
        else { return nil }
        return ("[1,null,null,null,\"\(id)\",null,null,0,[4,5,6,8],null,null,1,null,null,\(number)]", number)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
