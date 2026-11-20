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
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        let base = root.pathComponents.count
        for case let u as URL in e {
            let depth = u.pathComponents.count - base
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
