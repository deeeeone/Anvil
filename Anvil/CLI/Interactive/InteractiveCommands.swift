import Foundation

/// The slash commands the terminal session understands, and the completion of names and @mentions.
/// Pure apart from `projectFiles`, which reads the folder once when the session starts.
enum InteractiveCommands {
    struct Entry: Equatable {
        var name: String
        var summary: String
        var custom: Bool
    }

    /// The built-in commands this session implements. Custom project commands come after them.
    static let builtIns: [Entry] = [
        Entry(name: "help", summary: "list the commands", custom: false),
        Entry(name: "mode", summary: "permission mode: /mode ask, edits, plan or bypass", custom: false),
        Entry(name: "model", summary: "list models, or switch: /model ID", custom: false),
        Entry(name: "cost", summary: "tokens and cost for this session", custom: false),
        Entry(name: "undo", summary: "undo the file changes of the last request", custom: false),
        Entry(name: "clear", summary: "start a fresh session", custom: false),
        Entry(name: "sessions", summary: "list this project's sessions", custom: false),
        Entry(name: "resume", summary: "resume a session by its ID: /resume ID", custom: false),
        Entry(name: "compact", summary: "summarise the conversation to free context", custom: false),
        Entry(name: "init", summary: "create or improve AGENTS.md for this project", custom: false),
        Entry(name: "exit", summary: "quit (also Ctrl-D)", custom: false),
    ]

    static func all(project: URL?) -> [Entry] {
        builtIns + SlashCommands.custom(project: project).map {
            Entry(name: $0.name, summary: $0.summary, custom: true)
        }
    }

    /// The `/help` text: one line per command.
    static func helpText(project: URL?) -> String {
        let width = all(project: project).map { $0.name.count }.max() ?? 0
        return all(project: project).map { entry in
            "/" + entry.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + entry.summary
                + (entry.custom ? "  (custom)" : "")
        }.joined(separator: "\n")
    }

    /// The token ending at `cursor` (characters), and where it starts.
    static func token(in text: String, cursor: Int) -> (text: String, start: Int) {
        let chars = Array(text)
        let end = min(max(0, cursor), chars.count)
        var start = end
        while start > 0 && !chars[start - 1].isWhitespace { start -= 1 }
        return (String(chars[start..<end]), start)
    }

    /// Full replacements for the token at `cursor`, as the editor expects them. `/` completes command names at the
    /// start of the line; `@` completes project paths from `files`.
    static func completions(text: String, cursor: Int, project: URL?, files: [String]) -> [String] {
        let tok = token(in: text, cursor: cursor)
        let word = tok.text
        if word.hasPrefix("/") && tok.start == 0 {
            let q = word.dropFirst().lowercased()
            return all(project: project).filter { $0.name.hasPrefix(q) }.map { "/" + $0.name + " " }
        }
        if word.hasPrefix("@") {
            let q = String(word.dropFirst())
            return Mentions.suggestions(q, files: files).map { "@" + $0.token }
        }
        return []
    }

    /// Project files for @-completion: relative paths, skipping the usual dependency and build folders and hidden
    /// entries. Stops after `limit` files so a huge tree cannot stall the start-up.
    static func projectFiles(root: URL, limit: Int = 5000) -> [String] {
        var out: [String] = []
        let base = root.standardizedFileURL.path + "/"
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir && ProjectContext.skipDirs.contains(name) { e.skipDescendants(); continue }
            if isDir { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base) { out.append(String(path.dropFirst(base.count))) }
            if out.count >= limit { break }
        }
        return out.sorted()
    }

    /// Splits a typed line into a command name and its arguments, or nil when it is not a command.
    static func parse(_ line: String) -> (name: String, args: String)? {
        SlashCommands.split(line)
    }
}
