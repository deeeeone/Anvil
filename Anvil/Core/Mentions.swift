import Foundation

/// @-mentions in the composer: @path/to/file, @folder/, and a few specials, expanded into attachments on send.
nonisolated enum Mentions {
    struct Special: Sendable { var token: String; var label: String }
    static let specials = [
        Special(token: "git-diff", label: "the current git diff"),
        Special(token: "git-status", label: "git status"),
        Special(token: "last-output", label: "the last command's output"),
    ]

    /// The @token being typed at the end of `text`, if any ("fix @src/pri" → "src/pri").
    static func activeQuery(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }   // an email address, not a mention
        let q = String(text[text.index(after: at)...])
        return q.contains(where: { $0.isWhitespace }) ? nil : q
    }

    /// Mentioned tokens in a message, in order.
    static func tokens(in text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"(?:^|\s)@([\w./\-]+)"#)
        let ns = NSString(string: text)
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    }

    /// Ranked completions: specials first when they match, then files and folders whose path contains the query.
    static func suggestions(_ query: String, files: [String], limit: Int = 8) -> [(token: String, label: String)] {
        let q = query.lowercased()
        var out: [(String, String)] = specials.filter { q.isEmpty || $0.token.hasPrefix(q) }.map { ($0.token, $0.label) }
        var folders = Set<String>()
        for f in files {
            var parts = f.split(separator: "/").dropLast()
            while !parts.isEmpty { folders.insert(parts.joined(separator: "/") + "/"); parts = parts.dropLast() }
        }
        func score(_ p: String) -> Int? {
            let l = p.lowercased()
            if q.isEmpty { return p.count }
            if NSString(string: l).lastPathComponent.hasPrefix(q) { return p.count }
            if l.hasPrefix(q) { return 1000 + p.count }
            if l.contains(q) { return 2000 + p.count }
            return nil
        }
        let ranked = (files.map { ($0, "file") } + folders.map { ($0, "folder") })
            .compactMap { p, kind in score(p).map { (p, kind, $0) } }
            .sorted { $0.2 < $1.2 }
        out += ranked.prefix(limit).map { ($0.0, $0.1) }
        return Array(out.prefix(limit))
    }

    /// The attachments block for the mentions in `text` (empty when there are none).
    static func expand(_ text: String, root: URL, lastOutput: String?) async -> String {
        var blocks: [String] = []
        for t in Array(NSOrderedSet(array: tokens(in: text))) as? [String] ?? [] {
            switch t {
            case "git-diff":
                let d = await Git.diff(root)
                blocks.append("git diff:\n" + (d.isEmpty ? "(no unstaged changes)" : Fmt.clip(d, max: 16000)))
            case "git-status":
                let st = await Git.run(["status", "--short", "--branch"], in: root)
                blocks.append("git status:\n" + st.stdout)
            case "last-output":
                blocks.append("last command output:\n" + Fmt.clip(lastOutput ?? "(no command has run yet)", max: 12000))
            default:
                let url = Paths.resolve(t, base: root)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                    blocks.append("folder \(t) contains: " + names.prefix(200).joined(separator: ", "))
                } else if let content = try? FileTools.readText(url) {
                    let (body, _, _, total) = FileTools.numbered(content, offset: 1, limit: 600)
                    blocks.append("file \(t) (\(total) lines):\n" + body + (total > 600 ? "\n(first 600 lines; read_file for the rest)" : ""))
                }
            }
        }
        return blocks.isEmpty ? "" : "ATTACHED BY THE OWNER (from @-mentions)\n" + blocks.joined(separator: "\n\n") + "\n\n"
    }
}

/// Spotting lasting preferences in the owner's corrections ("don't use classes here", "tabs not spaces").
nonisolated enum Conventions {
    /// Cheap first filter before asking a model.
    static func looksLikeCorrection(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.count < 400 else { return false }
        let cues = ["don't ", "dont ", "do not ", "never ", "always ", "instead of", "rather than", "stop ", "no, ", "not like that", "prefer ",
                    "use tabs", "use spaces", " not spaces", " not tabs", "should use", "please use", "avoid ", "we use", "in this project"]
        return cues.contains { t.contains($0) }
    }

    static func prompt(_ text: String) -> String {
        """
        The owner wrote this to their coding agent during a session:
        "\(Fmt.line(text, 400))"
        If it states a lasting preference about how code in this project should be written, or how the agent should work here \
        (not a one-off instruction for the current task), rewrite it as one short imperative line for a conventions list, \
        e.g. "Use tabs for indentation." Otherwise reply exactly: NONE
        """
    }

    /// Appends a line under "## Conventions" in AGENTS.md (creating either if needed). Returns the file.
    @discardableResult
    static func save(_ line: String, root: URL) throws -> URL {
        let existing = ["AGENTS.md", "CLAUDE.md"].map { root.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        let url = existing ?? root.appendingPathComponent("AGENTS.md")
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# AGENTS.md\n"
        let entry = "- " + line.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "-• "))
        if text.contains(entry) { return url }
        if let r = text.range(of: "## Conventions") {
            let after = text[r.upperBound...]
            let next = after.range(of: "\n## ")?.lowerBound ?? text.endIndex
            var insertAt = next
            if insertAt > r.upperBound, text[text.index(before: insertAt)] == "\n" { insertAt = text.index(before: insertAt) }
            text.insert(contentsOf: "\n" + entry, at: insertAt)
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n## Conventions\n" + entry + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Turning a request that went well into a reusable SKILL.md.
nonisolated enum SkillBuilder {
    static func prompt(request: String, steps: [String], answer: String) -> String {
        """
        Turn this successful coding-agent run into a reusable skill (Claude's SKILL.md format) for similar requests in this project.
        REQUEST: \(Fmt.line(request, 500))
        STEPS TAKEN:
        \(steps.prefix(40).map { "- " + Fmt.line($0, 160) }.joined(separator: "\n"))
        RESULT: \(Fmt.line(answer, 400))

        Reply with only a JSON object: {"name": "kebab-case-name", "description": "one line saying WHEN to use it", \
        "instructions": "numbered markdown steps: which files and commands, the order, gotchas found. Generalise beyond this one request. At most 25 lines."}
        """
    }

    /// Writes .anvil/skills/<name>/SKILL.md in the project. Returns the file.
    static func save(json: JSON, root: URL) throws -> URL {
        guard let name = json["name"]?.string, let desc = json["description"]?.string, let body = json["instructions"]?.string else {
            throw ToolFailure("the model didn't return name, description and instructions")
        }
        let slug = SkillLibrary.slug(name)
        let dir = root.appendingPathComponent(".anvil/skills/\(slug)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("SKILL.md")
        try "---\nname: \(slug)\ndescription: \(Fmt.plain(desc).replacingOccurrences(of: "\n", with: " "))\n---\n\n\(Fmt.plain(body).trimmingCharacters(in: .whitespacesAndNewlines))\n"
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
