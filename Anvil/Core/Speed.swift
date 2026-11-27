import Foundation

/// How big a request looks, decided before the first turn (no model call).
nonisolated enum RequestSize: String, Sendable {
    case simple     // rename, typo, small tweak: fast model, low effort
    case question   // explain or locate: medium effort, no edits expected
    case feature    // the default: strong model, high effort
    case hard       // flaky, crash, race, perf: high effort, escalate after the first failure

    static func classify(_ goal: String) -> RequestSize {
        let g = goal.lowercased()
        let words = g.split { $0.isWhitespace }.count
        func has(_ list: [String]) -> Bool { list.contains { g.contains($0) } }
        if has(["flaky", "intermittent", "race condition", "deadlock", "memory leak", "segfault", "crash", "hangs", "too slow", "performance",
                "sometimes wrong", "sometimes fails", "heisenbug", "regression"]) { return .hard }
        let editVerbs = ["add", "fix", "change", "make", "create", "write", "implement", "refactor", "rename", "remove", "delete", "update", "move", "replace", "build"]
        let asksOnly = g.hasSuffix("?") || has(["explain", "what does", "how does", "where is", "where does", "why does", "question only", "don't change", "do not change"])
        if asksOnly && !(has(editVerbs.map { $0 + " " }) && !has(["don't change", "do not change", "question only"])) { return .question }
        // A UI request is never "simple": even a one-word fix on a page needs the browser check.
        if words <= 25 && !SkillLibrary.isUIRequest(goal) && has(["rename ", "typo", "spelling", "comment", "bump ", "version to", "change the text", "reword", "capitaliz", "indent", "format "]) { return .simple }
        return .feature
    }

    var effort: String {
        switch self { case .simple: return "low"; case .question: return "medium"; case .feature, .hard: return "high" }
    }
}

/// Picks the reasoning effort for each turn from what the agent is likely doing next.
nonisolated enum AdaptiveEffort {
    struct State {
        var step: Int
        var size: RequestSize
        var editedThisRequest: Bool
        var lastBatchExploratory: Bool
        var lastBatchFailed: Bool
        var verifiedSinceEdit: Bool
        var parseFailures: Int
    }

    /// `full` is the owner's effort setting (the ceiling).
    static func effort(_ s: State, full: String) -> String {
        if s.lastBatchFailed || s.parseFailures > 0 { return full }                 // something broke: think properly
        if s.step == 1 {
            // The first turn (and a plan) sets the approach: features and hard requests get the owner's full effort.
            return s.size == .feature || s.size == .hard ? full : cap(s.size.effort, full)
        }
        if s.editedThisRequest && s.verifiedSinceEdit { return cap("low", full) }   // tests passed: wrapping up
        if s.size == .simple { return cap("low", full) }
        if s.lastBatchExploratory && !s.editedThisRequest {
            // After reading, the next turn usually decides the change: full effort, except for questions.
            return s.size == .question ? cap("medium", full) : full
        }
        return cap("medium", full)
    }

    static let order = ["low", "medium", "high", "max"]
    static func cap(_ e: String, _ ceiling: String) -> String {
        guard let i = order.firstIndex(of: e), let c = order.firstIndex(of: ceiling) else { return e }
        return order[min(i, c)]
    }
}

/// "Prefetch what's obviously next": code around the lines a failure points to, and around a few grep hits.
nonisolated enum Prefetch {
    /// (path, line) pairs found in tool output: Python tracebacks, Node stacks, compiler and pytest locations.
    static func locations(in output: String) -> [(String, Int)] {
        let patterns = [
            #"File "([^"]+)", line (\d+)"#,                              // Python
            #"\(?((?:\.{0,2}/)?[\w./\-]+\.(?:js|mjs|cjs|ts|tsx|jsx)):(\d+):\d+\)?"#,   // Node / TS stacks
            #"^((?:\.{0,2}/)?[\w./\-]+\.(?:swift|c|cc|cpp|h|go|rs|java|kt|rb|php|py)):(\d+)(?::\d+)?"#,   // compilers, pytest
        ]
        var out: [(String, Int)] = []
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) else { continue }
            let ns = output as NSString
            for m in re.matches(in: output, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
                if let line = Int(ns.substring(with: m.range(at: 2))) { out.append((ns.substring(with: m.range(at: 1)), line)) }
            }
        }
        return out
    }

    /// Up to `limit` snippets for locations inside the project (innermost frames first, no duplicates, no vendor code).
    static func snippets(for output: String, root: URL, limit: Int = 3, radius: Int = 6) -> String {
        var seen = Set<String>()
        var picked: [(URL, Int)] = []
        for (path, line) in locations(in: output).reversed() {
            let url = Paths.resolve(path, base: root)
            guard Paths.isInside(url, root: root), FileManager.default.fileExists(atPath: url.path),
                  !ProjectContext.skipDirs.contains(where: { url.path.contains("/\($0)/") }) else { continue }
            let key = "\(url.path):\(line / (radius * 2))"
            guard seen.insert(key).inserted else { continue }
            picked.append((url, line))
            if picked.count >= limit { break }
        }
        return picked.compactMap { url, line in snippet(url, line: line, radius: radius, root: root) }.joined(separator: "\n")
    }

    static func snippet(_ url: URL, line: Int, radius: Int, root: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = DiffEngine.lines(text)
        guard line >= 1, line <= lines.count else { return nil }
        let lo = max(1, line - radius), hi = min(lines.count, line + radius)
        let body = (lo...hi).map { i in "\(i == line ? ">" : " ")\(i)\t\(lines[i - 1])" }.joined(separator: "\n")
        return "\(Paths.display(url, root: root)) around line \(line):\n\(body)"
    }

    /// For a grep with a handful of hits (and no context asked for), the code around each hit.
    static func grepContext(_ output: String, root: URL, maxHits: Int = 3) -> String? {
        let hits = output.split(separator: "\n").compactMap { l -> (String, Int)? in
            let parts = l.split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let n = Int(parts[1]) else { return nil }
            return (String(parts[0]), n)
        }
        guard !hits.isEmpty, hits.count <= maxHits else { return nil }
        let s = hits.compactMap { snippet(Paths.resolve($0.0, base: root), line: $0.1, radius: 4, root: root) }.joined(separator: "\n")
        return s.isEmpty ? nil : s
    }
}

/// A short summary of the project written once by a fast model and cached until the code changes.
nonisolated struct ProjectBrief: Codable, Sendable {
    var text: String
    var fingerprint: String
    var created: Date

    static func file(_ root: URL) -> URL {
        Paths.dir(Paths.sub("projects").appendingPathComponent(SessionStore.projectKey(root))).appendingPathComponent("brief.json")
    }

    static func load(_ root: URL) -> ProjectBrief? {
        guard let d = try? Data(contentsOf: file(root)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ProjectBrief.self, from: d)
    }

    func save(_ root: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(self) { try? d.write(to: Self.file(root), options: .atomic) }
    }

    /// Changes when files are added, removed or renamed, or symbols change (not on every keystroke inside a function).
    static func fingerprint(repoMap: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for b in repoMap.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        return String(hash, radix: 16)
    }

    static func prompt(root: URL, repoMap: String, layout: String) -> String {
        var extra = ""
        for name in ["README.md", "README", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Package.swift", "Makefile", "AGENTS.md", "CLAUDE.md"] {
            if let t = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) { extra += "\n--- \(name)\n" + Fmt.clip(t, max: 2500) }
        }
        return """
        Write a brief for a coding agent about to work on this project, so it can skip exploring. At most 180 words, plain text, \
        no preamble, no dashes as bullets are fine. Cover: what the project is; the main modules and what each does (with paths); \
        entry points; how to build, run and test it (exact commands only if you see evidence). If something is unclear, leave it out.

        LAYOUT
        \(layout)

        REPO MAP
        \(Fmt.clip(repoMap, max: 6000))
        \(extra)
        """
    }
}

/// An in-memory list of the project's files (and a small content cache), kept fresh by the file watcher and by the
/// agent's own edits, so glob and grep don't walk the whole tree every time on big repos.
final class FileIndex {
    static var shared: [String: FileIndex] = [:]
    static func of(_ root: URL) -> FileIndex {
        let key = root.standardizedFileURL.path
        if let i = shared[key] { return i }
        let i = FileIndex(root: root)
        shared[key] = i
        return i
    }

    let root: URL
    private var files: [URL]?
    private var builtAt = Date.distantPast
    init(root: URL) { self.root = root }

    /// The file list (built on first use, rebuilt when marked dirty).
    func list() async -> [URL] {
        if let files { return files }
        let r = root
        let built = await Task.detached { FileTools.walk(r) }.value
        files = built
        builtAt = Date()
        return built
    }

    var isBuilt: Bool { files != nil }

    /// Something changed on disk (watcher event or a shell command): rebuild on next use.
    func invalidate() { files = nil }

    /// The agent wrote or deleted a file: update in place (cheap).
    func noteChanged(_ url: URL, deleted: Bool) {
        guard files != nil else { return }
        let p = url.standardizedFileURL
        files!.removeAll { $0.standardizedFileURL == p }
        if !deleted { files!.append(p) }
    }
}
