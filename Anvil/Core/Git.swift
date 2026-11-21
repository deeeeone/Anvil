import Foundation

/// Thin wrapper over the git CLI, with pure parsers for testing.
nonisolated enum Git {
    struct FileStatus: Equatable, Sendable, Identifiable, Hashable {
        var path: String
        var index: Character
        var worktree: Character
        var id: String { path }
        var isUntracked: Bool { index == "?" }
        var isStaged: Bool { index != " " && index != "?" }
        var label: String {
            if isUntracked { return "untracked" }
            let c = isStaged ? index : worktree
            switch c {
            case "M": return isStaged ? "modified (staged)" : "modified"
            case "A": return "added"
            case "D": return isStaged ? "deleted (staged)" : "deleted"
            case "R": return "renamed"
            case "U": return "conflict"
            default: return String(c)
            }
        }
        var letter: String { isUntracked ? "U" : String(isStaged ? index : worktree) }
    }

    struct Status: Equatable, Sendable {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var files: [FileStatus] = []
        var isRepo = true
        var summary: String {
            guard isRepo else { return "not a git repository" }
            var s = branch ?? "detached HEAD"
            if ahead > 0 { s += " ↑\(ahead)" }
            if behind > 0 { s += " ↓\(behind)" }
            s += files.isEmpty ? ", clean" : ", \(files.count) changed"
            return s
        }
    }

    /// Parses `git status --porcelain=v1 -b`.
    static func parseStatus(_ text: String) -> Status {
        var st = Status()
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            if line.hasPrefix("## ") {
                var head = String(line.dropFirst(3))
                if let r = head.range(of: " [") {
                    let info = head[r.upperBound...].dropLast()
                    for part in info.components(separatedBy: ", ") {
                        let bits = part.split(separator: " ")
                        if bits.count == 2, let n = Int(bits[1]) { if bits[0] == "ahead" { st.ahead = n } else if bits[0] == "behind" { st.behind = n } }
                    }
                    head = String(head[..<r.lowerBound])
                }
                if head.hasPrefix("No commits yet on ") { st.branch = String(head.dropFirst("No commits yet on ".count)); continue }
                if head.hasPrefix("HEAD (no branch)") { st.branch = nil; continue }
                let parts = head.components(separatedBy: "...")
                st.branch = parts[0]
                if parts.count > 1 { st.upstream = parts[1] }
                continue
            }
            guard line.count >= 4 else { continue }
            let chars = Array(line)
            var path = String(chars[3...])
            if let r = path.range(of: " -> ") { path = String(path[r.upperBound...]) }
            if path.hasPrefix("\"") && path.hasSuffix("\"") { path = String(path.dropFirst().dropLast()) }
            st.files.append(FileStatus(path: path, index: chars[0], worktree: chars[1]))
        }
        return st
    }

    static func run(_ args: [String], in root: URL, timeout: Double = 30) async -> ProcessOutput {
        await ProcessRunner.run("/usr/bin/git", ["-C", root.path, "-c", "core.pager=cat", "-c", "color.ui=false"] + args, cwd: root, timeout: timeout)
    }

    static func status(_ root: URL) async -> Status {
        let r = await run(["status", "--porcelain=v1", "-b", "-uall"], in: root)
        if r.status != 0 { var s = Status(); s.isRepo = false; return s }
        return parseStatus(r.stdout)
    }

    static func diff(_ root: URL, path: String? = nil, staged: Bool = false) async -> String {
        var args = ["diff", "--no-ext-diff"]
        if staged { args.append("--cached") }
        if let path { args += ["--", path] }
        return await run(args, in: root).stdout
    }

    /// Diff of everything that would be committed by "stage all": tracked changes plus new files.
    static func fullDiff(_ root: URL) async -> String {
        var out = await run(["diff", "--no-ext-diff", "HEAD"], in: root).stdout
        if out.isEmpty { out = await run(["diff", "--no-ext-diff", "--cached"], in: root).stdout + (await run(["diff", "--no-ext-diff"], in: root).stdout) }
        let untracked = await run(["ls-files", "--others", "--exclude-standard"], in: root).stdout
        for f in untracked.split(separator: "\n").prefix(20) {
            let content = (try? String(contentsOf: root.appendingPathComponent(String(f)), encoding: .utf8)) ?? "(binary)"
            out += "\nnew file: \(f)\n" + Fmt.clip(content, max: 2000)
        }
        return out
    }

    static func stageAll(_ root: URL) async -> ProcessOutput { await run(["add", "-A"], in: root) }
    static func stage(_ root: URL, path: String) async -> ProcessOutput { await run(["add", "--", path], in: root) }
    static func unstage(_ root: URL, path: String) async -> ProcessOutput { await run(["reset", "-q", "HEAD", "--", path], in: root) }

    static func commit(_ root: URL, message: String) async -> ProcessOutput {
        await run(["commit", "-m", message], in: root)
    }

    static func log(_ root: URL, count: Int = 15) async -> String {
        await run(["log", "--oneline", "-n", "\(count)"], in: root).stdout
    }

    /// Creates a worktree for a session on a new branch. Returns (folder, branch, base branch).
    static func addWorktree(_ root: URL, name: String) async -> Result<(URL, String, String), Error> {
        let st = await status(root)
        guard st.isRepo else { return .failure(ToolFailure("This folder isn't a git repository.")) }
        let head = await run(["rev-parse", "--verify", "HEAD"], in: root)
        guard head.status == 0 else { return .failure(ToolFailure("Make a first commit before starting a worktree session.")) }
        let base = st.branch ?? "HEAD"
        let short = String(UUID().uuidString.prefix(6)).lowercased()
        let branch = "anvil/\(SkillLibrary.slug(name).prefix(24))-\(short)"
        let dir = root.deletingLastPathComponent().appendingPathComponent(".anvil-worktrees").appendingPathComponent("\(root.lastPathComponent)-\(short)")
        try? FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = await run(["worktree", "add", "-b", branch, dir.path], in: root, timeout: 120)
        guard r.status == 0 else { return .failure(ToolFailure("git worktree add failed: \(r.combined)")) }
        return .success((dir, branch, base))
    }

    /// Merges a session branch into the project's current branch (no fast-forward, so it shows as one unit).
    static func mergeBranch(_ root: URL, branch: String, message: String) async -> ProcessOutput {
        await run(["merge", "--no-ff", branch, "-m", message], in: root, timeout: 120)
    }

    static func initRepo(_ root: URL) async -> ProcessOutput { await run(["init"], in: root) }

    static func commitPrompt(diff: String) -> String {
        """
        Write a git commit message for this diff. Format: a subject line in the imperative mood under 70 characters, \
        then a blank line and a short body (1-4 lines) only if it helps explain why. No em dashes, no quotes around it, \
        no code fences, no preamble. Output only the message.

        \(Fmt.clip(diff, max: 24000))
        """
    }

    /// Strips fences, quotes and preambles some models add around a commit message.
    static func cleanCommitMessage(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"```[a-z]*\n([\s\S]*?)```"#, options: .regularExpression) {
            s = String(s[r]).replacingOccurrences(of: #"^```[a-z]*\n"#, with: "", options: .regularExpression).replacingOccurrences(of: "```", with: "")
        }
        let preambles = ["here is the commit message:", "here's the commit message:", "commit message:", "here is a commit message:"]
        for p in preambles where s.lowercased().hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 1, (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) { s = String(s.dropFirst().dropLast()) }
        return Fmt.plain(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
