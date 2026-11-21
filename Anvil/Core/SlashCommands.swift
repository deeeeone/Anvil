import Foundation

/// Built-in and custom slash commands. Custom ones are markdown files whose body becomes the prompt
/// ($ARGUMENTS is replaced with whatever follows the command).
nonisolated struct SlashCommand: Identifiable, Hashable, Sendable {
    var name: String
    var summary: String
    var body: String?          // custom commands only
    var source: String         // "built-in", "project", "user", "claude"
    var id: String { name }

    func expand(_ args: String) -> String {
        let b = body ?? ""
        return b.contains("$ARGUMENTS") ? b.replacingOccurrences(of: "$ARGUMENTS", with: args) : (args.isEmpty ? b : b + "\n\n" + args)
    }
}

nonisolated enum SlashCommands {
    static let builtIns: [SlashCommand] = [
        .init(name: "init", summary: "create or improve AGENTS.md for this project", source: "built-in"),
        .init(name: "clear", summary: "start a fresh session", source: "built-in"),
        .init(name: "compact", summary: "summarise the conversation to free context (optional focus)", source: "built-in"),
        .init(name: "model", summary: "show or switch the model: /model <id>", source: "built-in"),
        .init(name: "cost", summary: "token usage and cost for this session", source: "built-in"),
        .init(name: "mode", summary: "permission mode: ask, edits, plan or bypass", source: "built-in"),
        .init(name: "undo", summary: "undo the file changes of the last task", source: "built-in"),
        .init(name: "queue", summary: "add a background task (runs in its own worktree)", source: "built-in"),
        .init(name: "limit", summary: "stop each request at a cost or step limit: /limit $0.02 40", source: "built-in"),
        .init(name: "commit", summary: "stage all and commit with a generated message", source: "built-in"),
        .init(name: "diff", summary: "show the git diff in the inspector", source: "built-in"),
        .init(name: "skills", summary: "list available skills", source: "built-in"),
        .init(name: "mcp", summary: "MCP server status", source: "built-in"),
        .init(name: "effort", summary: "thinking effort: low, medium, high or max", source: "built-in"),
        .init(name: "help", summary: "list commands", source: "built-in"),
    ]

    static func folders(project: URL?) -> [(URL, String)] {
        var out: [(URL, String)] = []
        if let project {
            out.append((project.appendingPathComponent(".anvil/commands"), "project"))
            out.append((project.appendingPathComponent(".claude/commands"), "project"))
        }
        out.append((Paths.support.appendingPathComponent("commands"), "user"))
        out.append((Paths.home.appendingPathComponent(".claude/commands"), "claude"))
        return out
    }

    static func custom(project: URL?) -> [SlashCommand] {
        var seen = Set(builtIns.map(\.name))
        var out: [SlashCommand] = []
        for (dir, source) in folders(project: project) {
            let base = dir.resolvingSymlinksInPath().path
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let f as URL in e where f.pathExtension == "md" {
                // Nested folders become namespaced commands: frontend/review.md → /frontend:review
                let full = f.resolvingSymlinksInPath().path
                guard full.hasPrefix(base + "/") else { continue }
                let rel = String(full.dropFirst(base.count + 1).dropLast(3))
                let name = rel.replacingOccurrences(of: "/", with: ":").lowercased()
                guard seen.insert(name).inserted, let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let parsed = SkillLibrary.parse(text)
                let summary = parsed.meta["description"] ?? parsed.body.split(separator: "\n").first.map { Fmt.line(String($0), 80) } ?? ""
                out.append(SlashCommand(name: name, summary: summary, body: parsed.body, source: source))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    static func all(project: URL?) -> [SlashCommand] { builtIns + custom(project: project) }

    /// "/model foo bar" → ("model", "foo bar"); nil when the text isn't a command.
    static func split(_ text: String) -> (name: String, args: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), t.count > 1, !t.hasPrefix("//") else { return nil }
        let body = t.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.contains("/") else { return nil }   // an absolute path, not a command
        let args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.lowercased(), args)
    }

    static func suggestions(_ text: String, project: URL?) -> [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return [] }
        let q = text.dropFirst().lowercased()
        return all(project: project).filter { q.isEmpty || $0.name.hasPrefix(q) || $0.name.contains(q) }
    }
}
