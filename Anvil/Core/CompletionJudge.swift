import Foundation

/// The judge's answer about a request: done, or the concrete things still open.
nonisolated struct Verdict: Codable, Equatable, Sendable {
    var done: Bool
    var missing: [String]
    var problems: [String]

    /// Everything still open. A verdict is only done when nothing is open.
    var open: [String] { missing + problems }
}

/// A hidden completion check. A second model reads the request, its changes and the final answer, and lists only
/// concrete misses. Its prompt and verdict never enter the conversation.
nonisolated enum CompletionJudge {
    /// Reads a judge reply: a json block or bare JSON, optionally wrapped as {"say": "<json string>"}.
    static func parse(_ reply: String) -> Verdict? {
        guard let obj = jsonObject(reply), let done = obj["done"] as? Bool else { return nil }
        let missing = strings(obj["missing"]), problems = strings(obj["problems"])
        return Verdict(done: done && missing.isEmpty && problems.isEmpty, missing: missing, problems: problems)
    }

    static func strings(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The first JSON object in a reply: a fenced block, or the text from the first { to the last }.
    static func jsonObject(_ raw: String, depth: Int = 0) -> [String: Any]? {
        var candidates: [String] = []
        let ns = raw as NSString
        if let re = try? NSRegularExpression(pattern: "```(?:json|JSON)?[ \\t]*\\n?([\\s\\S]*?)```") {
            for m in re.matches(in: raw, range: NSRange(location: 0, length: ns.length)) { candidates.append(ns.substring(with: m.range(at: 1))) }
        }
        if let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open <= close { candidates.append(String(raw[open...close])) }
        for text in candidates {
            var obj: [String: Any]?
            if let data = text.data(using: .utf8) { obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            if obj == nil, let json = ActionParser.parseLenient(text), case .object = json { obj = json.anyValue as? [String: Any] }
            guard let found = obj else { continue }
            // Some models wrap the object as {"say": "<json string>"}.
            if depth < 2, found["done"] == nil, found["criteria"] == nil, found["missing"] == nil,
               let say = found["say"] as? String, let inner = jsonObject(say, depth: depth + 1) {
                return inner
            }
            return found
        }
        return nil
    }

    /// The judge's prompt: the request, its definition of done, the changes, the check results and the final answer.
    static func prompt(goal: String, criteria: [String], diff: String, files: String, lastCheck: String, answer: String) -> String {
        var p = """
        COMPLETION JUDGE. Decide whether an AI coding agent has really finished this request. You do not do the work.

        REQUEST
        \(Fmt.clip(goal, max: 2000))

        """
        if !criteria.isEmpty { p += "DEFINITION OF DONE (the checks the work must pass)\n" + criteria.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        p += "CHECK RESULTS (commands the app ran, files it looked for)\n" + (lastCheck.isEmpty ? "none\n" : Fmt.clip(lastCheck, max: 6000) + "\n") + "\n"
        p += "CHANGES MADE FOR THIS REQUEST\n" + (diff.isEmpty ? "no files changed\n" : Fmt.clip(diff, max: 24000) + "\n")
        if !files.isEmpty { p += "\nCURRENT CONTENT OF THE CHANGED FILES (for context)\n" + files + "\n" }
        p += "\nTHE AGENT'S FINAL ANSWER\n" + Fmt.clip(answer, max: 4000) + "\n\n"
        p += """
        RULES
        - List ONLY concrete misses tied to the request or the definition of done. Each needs evidence: a failing command and its output, a missing file, a stated requirement with the line that doesn't meet it, or a claim in the final answer that the changes don't back up.
        - No style points, no new scope, no "could also", no optional improvements.
        - If nothing concrete is missing, say "done": true.
        - For a request with a user interface (a page, screen, site or component), the answer must be backed by browser evidence in this session: the page was opened at its route and the requested interactions were exercised. If the agent never showed the page working in the browser, list that as missing: "UI not verified in the browser: <what was not checked>".
        - Reply with one JSON object only, in a ```json block, shaped like {"done": true or false, "missing": ["..."], "problems": ["..."]}
        """
        return p
    }

    /// The judge model for a session. A setting other than "auto" wins when it's available. "auto" pairs
    /// gemini-4-hydrogen with gemini-neon; other models judge with themselves.
    static func judgeModel(for sessionModel: String, setting: String, available: [String]) -> (model: String, note: String?) {
        let pick = setting.trimmingCharacters(in: .whitespaces)
        var model = sessionModel
        if !pick.isEmpty && pick != "auto" && available.contains(pick) {
            model = pick
        } else if sessionModel == "gemini-4-hydrogen" && available.contains("gemini-neon") {
            model = "gemini-neon"
        }
        let note = model == "gemini-neon" && sessionModel == "gemini-4-hydrogen"
            ? "gemini-neon may be the same model as gemini-4-hydrogen over Gemini web" : nil
        return (model, note)
    }

    /// Removes the <check>…</check> notes from a stored user message (they are for the next turn only).
    static func strippingChecks(_ text: String) -> String {
        guard text.contains("<check>") else { return text }
        let re = try! NSRegularExpression(pattern: "<check>[\\s\\S]*?</check>\\n?")
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    /// The note put in the next observation when the check finds open items.
    static func checkNote(_ misses: [String]) -> String {
        "<check>A completion check found these unfinished:\n" + misses.map { "- \($0)" }.joined(separator: "\n") + "\nFix them, verify, then finish.</check>"
    }

    /// Normalised text of a miss, so the same miss worded twice still counts as a repeat.
    static func key(_ miss: String) -> String {
        miss.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    static func unresolvedLine(_ items: [String]) -> String {
        "Unresolved after review: " + items.joined(separator: "; ")
    }

    /// Stop rules for one request's judge rounds: a miss that keeps coming back after two fix attempts is unresolved,
    /// and the rounds stop at the cap.
    struct Tracker: Sendable {
        var cap: Int
        private(set) var rounds = 0
        private var counts: [String: Int] = [:]
        private(set) var unresolved: [String] = []

        init(cap: Int) { self.cap = cap }

        /// Records one round's misses and returns the ones still worth fixing.
        mutating func record(_ misses: [String]) -> [String] {
            rounds += 1
            var fix: [String] = []
            for m in misses {
                let k = CompletionJudge.key(m)
                counts[k, default: 0] += 1
                if counts[k]! > 2 {
                    if !unresolved.contains(m) { unresolved.append(m) }
                } else if !fix.contains(m) {
                    fix.append(m)
                }
            }
            return fix
        }

        var exhausted: Bool { rounds >= cap }
    }
}
