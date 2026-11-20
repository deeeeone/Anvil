import Foundation

nonisolated struct AgentAction: Sendable, Equatable {
    var tool: String
    var args: JSON
}

nonisolated struct AgentReply: Sendable {
    var thought: String
    var say: String?
    var actions: [AgentAction]
    var done: Bool
    /// Milestones proposed before starting a big task (shown to the owner for approval).
    var plan: [String] = []
    /// 1-based milestone just finished.
    var milestone: Int?
}

nonisolated enum ParseError: Error, CustomStringConvertible {
    case noJSON, invalid(String)
    var description: String {
        switch self {
        case .noJSON: return "no ```json block found"
        case .invalid(let s): return "the json block could not be parsed (\(s))"
        }
    }
}

/// Lenient parser for the model's "reasoning + ```json block" replies (ported from Peep, coding aliases).
nonisolated enum ActionParser {
    static let nameKeys = ["tool", "action", "name", "type", "function", "cmd", "command_name"]
    static let argKeys = ["args", "arguments", "params", "parameters", "input", "inputs"]
    static let metaKeys: Set<String> = ["say", "thought", "thoughts", "reason", "reasoning", "risk", "why", "done", "status", "plan", "milestone"]
    static let completionNames: Set<String> = ["done", "finish", "final_answer", "answer", "complete", "attempt_completion"]

    static func parse(_ raw: String) throws -> AgentReply {
        let (jsonText, before) = try extractJSON(raw)
        guard let json = parseLenient(jsonText) else { throw ParseError.invalid(String(jsonText.prefix(80))) }
        var reply = AgentReply(thought: before, say: nil, actions: [], done: false)

        switch json {
        case .array(let items):
            reply.actions = items.compactMap(action(from:))
        case .object(let o):
            reply.say = (o["say"] ?? o["message"] ?? o["answer"] ?? o["reply"] ?? o["response"])?.string
            reply.done = o["done"]?.bool ?? (o["status"]?.string.map { ["done", "complete", "finished"].contains($0.lowercased()) } ?? false)
            reply.plan = (o["plan"]?.array ?? o["milestones"]?.array ?? []).compactMap { $0.string ?? $0["title"]?.string ?? $0["step"]?.string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            reply.milestone = o["milestone"]?.int
            if let list = (o["actions"] ?? o["steps"] ?? o["tool_calls"])?.array {
                reply.actions = list.compactMap(action(from:))
            } else if let a = o["action"]?.object ?? o["tool"]?.object {
                reply.actions = action(from: .object(a)).map { [$0] } ?? []
            } else if let a = action(from: json) {
                reply.actions = [a]
            }
        default:
            throw ParseError.invalid("top level must be an object")
        }

        // A "done" action is a completion signal, not a tool.
        if let i = reply.actions.firstIndex(where: { completionNames.contains($0.tool) }) {
            let a = reply.actions[i]
            let msg = a.args["message"]?.string ?? a.args["answer"]?.string ?? a.args["text"]?.string ?? a.args["say"]?.string ?? a.args["result"]?.string
            if let msg, !msg.isEmpty { reply.say = msg }
            reply.actions = Array(reply.actions[..<i])
            reply.done = true
        }
        if reply.actions.isEmpty && reply.say != nil && json["done"] == nil && reply.plan.isEmpty { reply.done = true }
        return reply
    }

    static func action(from j: JSON) -> AgentAction? {
        guard case .object(let o) = j else { return nil }
        guard let nameKey = nameKeys.first(where: { o[$0]?.string != nil }), let name = o[nameKey]?.string else { return nil }
        var args: JSON
        if let k = argKeys.first(where: { o[$0] != nil }), let a = o[k] {
            if case .string(let s) = a, let inner = parseLenient(s), case .object = inner { args = inner } else { args = a }
        } else {
            var flat = o
            flat.removeValue(forKey: nameKey)
            for k in metaKeys { flat.removeValue(forKey: k) }
            args = .object(flat)
        }
        if case .object = args {} else { args = .object(["value": args]) }
        return AgentAction(tool: normalize(name), args: args)
    }

    static func normalize(_ name: String) -> String {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        let aliases = [
            "bash": "shell", "run_shell": "shell", "terminal": "shell", "run_command": "shell", "execute_command": "shell", "sh": "shell", "zsh": "shell", "run": "shell",
            "read": "read_file", "cat": "read_file", "view": "read_file", "open_file": "read_file", "view_file": "read_file",
            "write": "write_file", "create_file": "write_file", "save_file": "write_file",
            "edit": "edit_file", "str_replace": "edit_file", "replace_in_file": "edit_file", "str_replace_editor": "edit_file", "apply_edit": "edit_file",
            "multiedit": "multi_edit", "multi_edit_file": "multi_edit", "edits": "multi_edit",
            "ls": "list_dir", "list_files": "list_dir", "list_directory": "list_dir", "dir": "list_dir",
            "search_code": "grep", "search_files": "grep", "ripgrep": "grep", "rg": "grep", "code_search": "grep",
            "find_files": "glob", "find": "glob", "file_search": "glob",
            "search_web": "web_search", "google": "web_search", "websearch": "web_search", "fetch": "fetch_url", "curl": "fetch_url", "webfetch": "fetch_url",
            "todos": "todo_write", "update_todos": "todo_write", "todowrite": "todo_write", "todo": "todo_write",
            "start_background": "start_process", "background": "start_process", "run_background": "start_process",
            "kill_process": "stop_process", "process_output": "read_process", "sleep": "wait",
            "rm": "delete_file", "remove_file": "delete_file",
        ]
        return aliases[n] ?? n
    }

    /// Finds the JSON payload: the last fence holding an object or array, or the outermost {...}.
    static func extractJSON(_ raw: String) throws -> (String, String) {
        let fence = try! NSRegularExpression(pattern: "```(?:json|JSON|javascript)?[ \\t]*\\n?([\\s\\S]*?)```")
        let ns = raw as NSString
        let matches = fence.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let body = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("{") || body.hasPrefix("[") {
                // Only a fence that really is our JSON (code in other fences may also start with "{").
                if parseLenient(body) != nil || matches.count == 1 {
                    let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (body, before)
                }
            }
        }
        // A fence that contains nested ``` (e.g. markdown in a write_file content) breaks the regex: use the last "```json" opener.
        if let r = raw.range(of: "```json", options: .backwards) {
            var body = String(raw[r.upperBound...])
            if let close = body.range(of: "```", options: .backwards) { body = String(body[..<close.lowerBound]) }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasPrefix("{"), parseLenient(body) != nil {
                return (body, String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // No fence: take the outermost balanced object.
        if let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end {
            return (String(raw[start...end]), String(raw[..<start]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw ParseError.noJSON
    }

    static func parseLenient(_ s: String) -> JSON? {
        if let j = JSON.parse(s) { return j }
        var t = s
        t = t.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        t = t.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*//.*$", with: "", options: .regularExpression)
        if let j = JSON.parse(t) { return j }
        t = t.replacingOccurrences(of: "\\bTrue\\b", with: "true", options: .regularExpression)
            .replacingOccurrences(of: "\\bFalse\\b", with: "false", options: .regularExpression)
            .replacingOccurrences(of: "\\bNone\\b", with: "null", options: .regularExpression)
        if let j = JSON.parse(t) { return j }
        if let j = JSON.parse(escapeNewlinesInStrings(t)) { return j }
        // Some models end with an extra closing brace or text after the object.
        if let j = JSON.parse(balancedPrefix(escapeNewlinesInStrings(t))) { return j }
        return nil
    }

    /// The first balanced {...} or [...] at the start of `s` (string-aware).
    static func balancedPrefix(_ s: String) -> String {
        var depth = 0, inString = false, escaped = false
        var out = ""
        for c in s {
            out.append(c)
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true } else if c == "{" || c == "[" { depth += 1 } else if c == "}" || c == "]" {
                depth -= 1
                if depth == 0 { return out }
            }
        }
        return s
    }

    static func escapeNewlinesInStrings(_ s: String) -> String {
        var out = ""
        var inString = false, escaped = false
        for c in s {
            if inString {
                if escaped { escaped = false; out.append(c); continue }
                if c == "\\" { escaped = true; out.append(c); continue }
                if c == "\"" { inString = false; out.append(c); continue }
                if c == "\n" { out += "\\n"; continue }
                if c == "\r" { out += "\\r"; continue }
                if c == "\t" { out += "\\t"; continue }
                out.append(c)
            } else {
                if c == "\"" { inString = true }
                out.append(c)
            }
        }
        return out
    }
}
