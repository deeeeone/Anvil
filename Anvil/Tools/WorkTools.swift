import Foundation

/// Web access, the todo list, skills and questions for the owner.
enum WorkTools {
    static func all() -> [ToolSpec] { [webSearch, fetchURL, todoWrite, listSkills, useSkill, askUser] }

    static let webSearch = ToolSpec(
        name: "web_search", kind: .network,
        signature: #"{"query": str, optional "limit": 1-15}"#,
        summary: "search the web (docs, error messages, package versions); returns titles, links, snippets",
        group: .web
    ) { a, _ in
        guard let q = a["query"]?.string ?? a["q"]?.string ?? a["value"]?.string, !q.isEmpty else { return .fail("missing query") }
        let results = try await WebSearch.search(q, limit: max(1, min(15, a["limit"]?.int ?? 8)))
        if results.isEmpty { return .ok("no results for \"\(q)\" (try different words)") }
        return .ok(results.enumerated().map { i, r in "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)" }.joined(separator: "\n"))
    }

    static let fetchURL = ToolSpec(
        name: "fetch_url", kind: .network,
        signature: #"{"url": str}"#,
        summary: "download a web page or API response as readable text (also works for localhost dev servers)",
        group: .web
    ) { a, _ in
        guard var s = a["url"]?.string ?? a["value"]?.string else { return .fail("missing url") }
        if !s.contains("://") { s = (s.hasPrefix("localhost") || s.hasPrefix("127.0.0.1") ? "http://" : "https://") + s }
        guard let url = URL(string: s), ["http", "https"].contains(url.scheme ?? "") else { return .fail("bad url") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        var text = String(decoding: data, as: UTF8.self)
        if a["raw"]?.bool != true && (type.contains("html") || text.lowercased().contains("<html")) { text = htmlToText(text) }
        var r = ToolResult(ok: (200..<400).contains(status), output: "HTTP \(status) \(type)\n" + Fmt.clip(text, max: 14000))
        r.stopBatch = !r.ok
        return r
    }

    static let todoWrite = ToolSpec(
        name: "todo_write", kind: .meta,
        signature: #"{"todos": [{"content": str, "status": "pending|in_progress|completed"}, ...]}"#,
        summary: "replace the visible todo list (use it for multi-step work; keep exactly one item in_progress)",
        group: .work
    ) { a, ctx in
        guard let list = a["todos"]?.array ?? a["items"]?.array else { return .fail("need a todos list") }
        let todos: [TodoItem] = list.compactMap { t in
            guard let c = t["content"]?.string ?? t["task"]?.string ?? t["title"]?.string ?? t.string else { return nil }
            let st = (t["status"]?.string ?? "pending").lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
            let status: TodoItem.Status = ["completed", "done", "complete"].contains(st) ? .completed : ["in_progress", "active", "doing"].contains(st) ? .inProgress : .pending
            return TodoItem(content: Fmt.plain(c), status: status)
        }
        ctx.todos = todos
        ctx.host?.agentTodos(todos)
        let done = todos.filter { $0.status == .completed }.count
        return .ok("todo list updated (\(done)/\(todos.count) done)")
    }

    static let listSkills = ToolSpec(
        name: "list_skills", kind: .meta,
        signature: #"{optional "query": str}"#,
        summary: "list playbook skills (project, Anvil's own and the owner's Claude Code skills)",
        group: .work
    ) { a, ctx in
        let all = SkillLibrary.all(project: ctx.root)
        let q = a["query"]?.string ?? ""
        let shown = q.isEmpty ? all : SkillLibrary.matching(q, project: ctx.root, limit: 25) + all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        var seen = Set<String>()
        let lines = shown.filter { seen.insert($0.name).inserted }.prefix(60).map { "- \($0.name) [\($0.source)]: \(Fmt.line($0.description, 140))" }
        return .ok(lines.isEmpty ? "no skills match \"\(q)\"" : lines.joined(separator: "\n"))
    }

    static let useSkill = ToolSpec(
        name: "use_skill", kind: .meta,
        signature: #"{"name": str}"#,
        summary: "load a skill's instructions, then follow them",
        group: .work
    ) { a, ctx in
        guard let n = a["name"]?.string ?? a["value"]?.string else { return .fail("missing name") }
        guard let s = SkillLibrary.find(n, project: ctx.root) else {
            let close = SkillLibrary.closest(to: n, project: ctx.root)
            return .fail("no skill named \"\(n)\"." + (close.isEmpty ? " Use list_skills." : " Closest: \(close.joined(separator: ", ")). Load one of those with use_skill."))
        }
        return .ok(Fmt.clip(SkillLibrary.load(s), max: 14000))
    }

    static let askUser = ToolSpec(
        name: "ask_user", kind: .meta,
        signature: #"{"question": str}"#,
        summary: "ask the owner a question only they can answer (a preference or missing fact); waits for the reply",
        group: .work
    ) { a, ctx in
        guard let q = a["question"]?.string ?? a["value"]?.string else { return .fail("missing question") }
        guard let answer = await ctx.host?.agentAsk(Fmt.plain(q)), !answer.isEmpty else {
            var r = ToolResult.fail("the owner didn't answer")
            r.endTask = "Stopped: waiting for your answer."
            return r
        }
        return .ok("the owner answered: \(answer)")
    }

    static func htmlToText(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "head"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<a [^>]*href=\"([^\"]+)\"[^>]*>", with: " [$1] ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&rsquo;": "'", "&mdash;": "-"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keyless web search through DuckDuckGo's HTML endpoint.
nonisolated enum WebSearch {
    struct Result: Sendable { var title: String; var url: String; var snippet: String }

    static func search(_ query: String, limit: Int) async throws -> [Result] {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        req.httpBody = Data((comps.percentEncodedQuery ?? "").utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return parse(String(decoding: data, as: UTF8.self), limit: limit)
    }

    static func parse(_ html: String, limit: Int) -> [Result] {
        var out: [Result] = []
        // Each result's markup starts at an element whose classes include result__body.
        let blocks = html.components(separatedBy: "result__body\"").dropFirst()
        for b in blocks {
            guard let link = firstMatch(#"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: b) else { continue }
            var url = decodeEntities(link[0])
            if url.contains("duckduckgo.com/l/"), let c = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url),
               let real = c.queryItems?.first(where: { $0.name == "uddg" })?.value { url = real }
            if url.contains("duckduckgo.com/y.js") { continue }   // ads
            let snippet = firstMatch(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: b)?[0] ?? ""
            out.append(Result(title: clean(link[1]), url: url, snippet: clean(snippet)))
            if out.count >= limit { break }
        }
        return out
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
    }

    private static func clean(_ s: String) -> String {
        decodeEntities(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func decodeEntities(_ s: String) -> String {
        var t = s
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }
}
