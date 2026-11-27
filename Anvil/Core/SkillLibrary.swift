import Foundation

/// A folder skill (Claude Code's SKILL.md format): name, a one-line description for picking it, and instructions loaded on demand.
nonisolated struct FolderSkill: Hashable, Sendable {
    var name: String
    var description: String
    var file: URL
    var source: String

    var folder: URL { file.deletingLastPathComponent() }
}

/// Finds skills in the project (.anvil/skills, .claude/skills), Anvil's own folder and ~/.claude/skills.
nonisolated enum SkillLibrary {
    static var anvilDir: URL { Paths.sub("skills") }

    /// Skills whose name or description matches a name that doesn't exist (e.g. "website" → impeccable, showcase-pages).
    static func closest(to name: String, project: URL?, limit: Int = 3) -> [String] {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        guard !words.isEmpty else { return [] }
        let scored = all(project: project).map { s -> (String, Int) in
            let n = s.name.lowercased(), d = s.description.lowercased()
            var score = 0
            for w in words {
                // "website" should also match "websites" and "web site"; compare on a stem.
                let stem = w.count > 5 ? String(w.dropLast(w.hasSuffix("s") ? 1 : 0)) : w
                if n.contains(stem) { score += 3 }
                if d.contains(stem) { score += 1 }
            }
            return (s.name, score)
        }
        return scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    static func all(project: URL?) -> [FolderSkill] {
        var roots: [(URL, String, Int)] = []
        if let project {
            roots.append((project.appendingPathComponent(".anvil/skills"), "project", 2))
            roots.append((project.appendingPathComponent(".claude/skills"), "project", 2))
        }
        roots.append((anvilDir, "anvil", 2))
        roots.append((Paths.home.appendingPathComponent(".claude/skills"), "claude", 3))
        var found: [FolderSkill] = []
        for (root, source, depth) in roots {
            for file in skillFiles(under: root, maxDepth: depth) {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let p = parse(text)
                let name = p.meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? file.deletingLastPathComponent().lastPathComponent
                let desc = p.meta["description"] ?? p.body.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
                found.append(FolderSkill(name: name, description: String(desc.prefix(400)), file: file, source: source))
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert(slug($0.name)).inserted }
    }

    static func find(_ name: String, project: URL?) -> FolderSkill? {
        let n = slug(name)
        let list = all(project: project)
        return list.first { slug($0.name) == n } ?? list.first { !n.isEmpty && slug($0.name).contains(n) }
    }

    static func words(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with", "my", "me", "it", "this", "that", "is", "be", "use", "when", "how", "can", "you", "i"]
        return Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Skills whose name/description overlap the goal, best first.
    static func matching(_ goal: String, project: URL?, limit: Int = 4) -> [FolderSkill] {
        let g = words(goal)
        guard !g.isEmpty else { return [] }
        return all(project: project).map { s -> (FolderSkill, Int) in
            (s, words(s.description).intersection(g).count + words(s.name).intersection(g).count * 2)
        }.filter { $0.1 >= 3 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Design skills in priority order: the first one that exists is loaded for a UI request.
    static let designSkills = ["frontend-design", "impeccable", "anti-slop"]

    /// Whole words that mark a request as UI work ("style" doesn't match "styled").
    static let uiWords: Set<String> = ["ui", "page", "pages", "site", "website", "landing", "frontend", "front", "component", "components",
                                       "dashboard", "design", "designs", "polished", "beautiful", "css", "react", "vue", "svelte", "html",
                                       "layout", "style", "styles", "styling", "interface", "tailwind"]

    static func isUIRequest(_ goal: String) -> Bool {
        let tokens = Set(goal.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return !tokens.isDisjoint(with: uiWords)
    }

    /// The design skill for a UI request: the first of `designSkills` found. Project skills come before ~/.claude/skills.
    /// `among` replaces the search (for tests).
    static func designSkill(project: URL?, among list: [FolderSkill]? = nil) -> FolderSkill? {
        let skills = list ?? all(project: project)
        for name in designSkills {
            // Plugin skills are named "plugin:skill", so the last part of the name counts too.
            if let s = skills.first(where: { slug($0.name) == name || slug($0.name.split(separator: ":").last.map(String.init) ?? "") == name }) {
                return s
            }
        }
        return nil
    }

    /// The skills block for the agent's first message. On the first turn of a UI request the design skill's instructions
    /// are included in full (clipped to 6000 characters); the other matches are listed for use_skill.
    static func skillNote(for goal: String, project: URL?, firstTurn: Bool) -> String {
        var matches = matching(goal, project: project)
        var design = ""
        if firstTurn && isUIRequest(goal), let s = designSkill(project: project) {
            design = "DESIGN SKILL (loaded automatically for this UI task): \(s.name)\n" + Fmt.clip(load(s), max: 6000) + "\n\n"
            matches.removeAll { $0 == s }
        }
        guard !matches.isEmpty else { return design }
        return design + "SKILLS THAT MAY HELP (load with use_skill before starting)\n" + matches.map { "- \($0.name): \(Fmt.line($0.description, 160))" }.joined(separator: "\n") + "\n\n"
    }

    static func load(_ s: FolderSkill) -> String {
        let body = parse((try? String(contentsOf: s.file, encoding: .utf8)) ?? "").body
        let files = (try? FileManager.default.contentsOfDirectory(atPath: s.folder.path))?.filter { $0 != "SKILL.md" && !$0.hasPrefix(".") }.sorted() ?? []
        var out = "SKILL \(s.name) (\(s.source)), folder: \(s.folder.path)\n"
        if !files.isEmpty { out += "files in it (read_file them when the instructions mention them): \(files.prefix(30).joined(separator: ", "))\n" }
        return out + "\n" + body
    }

    static func slug(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).split(separator: "-").joined(separator: "-")
    }

    private static func skillFiles(under root: URL, maxDepth: Int) -> [URL] {
        // Resolve symlinks first (/var vs /private/var), or the depth count is off by one.
        let root = root.resolvingSymlinksInPath()
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            let depth = e.level
            if [".trash", "cache", "node_modules", ".git"].contains(u.lastPathComponent) || depth > maxDepth { e.skipDescendants(); continue }
            if u.lastPathComponent == "SKILL.md" { out.append(u) }
            if out.count > 300 { break }
        }
        return out
    }

    /// YAML-ish frontmatter: `key: value` lines between --- markers.
    static func parse(_ text: String) -> (meta: [String: String], body: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return ([:], text) }
        var meta: [String: String] = [:]
        var key: String?
        for line in lines[1..<end] {
            if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if [">", "|", ">-", "|-"].contains(v) { v = "" }
                meta[key!] = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if let k = key {
                meta[k] = ((meta[k] ?? "") + " " + line.trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespaces)
            }
        }
        return (meta, lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
