import Foundation

/// How much the agent may do without asking (the same modes as Claude Code).
nonisolated enum PermissionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask, acceptEdits, plan, bypass
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ask: return "Ask before edits"
        case .acceptEdits: return "Auto-accept edits"
        case .plan: return "Plan only"
        case .bypass: return "Bypass permissions"
        }
    }
    var short: String {
        switch self { case .ask: return "Ask"; case .acceptEdits: return "Auto-edit"; case .plan: return "Plan"; case .bypass: return "Bypass" }
    }
    var symbol: String {
        switch self { case .ask: return "hand.raised"; case .acceptEdits: return "pencil.and.outline"; case .plan: return "list.bullet.clipboard"; case .bypass: return "bolt.shield" }
    }
    var next: PermissionMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

nonisolated enum ToolKind: String, Sendable { case read, edit, exec, network, meta }

nonisolated enum PermissionDecision: Equatable, Sendable {
    case allow
    case ask(String)
    case deny(String)
}

/// Pure permission policy, so it can be tested without the UI.
nonisolated enum Permissions {
    /// - Parameters:
    ///   - command: the shell command for exec tools.
    ///   - paths: files an edit tool will write.
    ///   - allowed: command keys the owner allowed for this session ("npm test", "make").
    static func decide(mode: PermissionMode, kind: ToolKind, command: String? = nil, paths: [URL] = [],
                       root: URL, allowed: Set<String> = []) -> PermissionDecision {
        switch kind {
        case .read, .network, .meta:
            return .allow
        case .edit:
            let outside = paths.filter { !Paths.isInside($0, root: root) }
            let gitInternal = paths.filter { $0.standardizedFileURL.path.contains("/.git/") }
            if mode == .plan { return .deny("Plan mode is read-only: no file changes. Finish investigating and reply with a plan.") }
            if !outside.isEmpty { return .ask("writes outside the project: \(outside.map { Paths.display($0, root: root) }.joined(separator: ", "))") }
            if !gitInternal.isEmpty { return .ask("edits files inside .git") }
            switch mode {
            case .ask: return .ask("edit")
            default: return .allow
            }
        case .exec:
            let cmd = command ?? ""
            if let danger = dangerReason(cmd) {
                return mode == .plan ? .deny("Plan mode is read-only and this command is destructive (\(danger)).") : .ask(danger)
            }
            if mode == .bypass { return .allow }
            if isReadOnly(cmd) { return .allow }
            if mode == .plan { return .deny("Plan mode allows only read-only commands (ls, cat, git status, grep...). Reply with a plan instead.") }
            if allowed.contains(commandKey(cmd)) { return .allow }
            return .ask("run command")
        }
    }

    /// Why a command is destructive or publishes something (always asks, whatever the mode).
    static func dangerReason(_ command: String) -> String? {
        let c = " " + command.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let rules: [(String, String)] = [
            (#"(^|[;&|\s])sudo\s"#, "uses sudo"),
            (#"(^|[;&|\s])rm\s+(-[a-z]*\s+)*-[a-z]*r"#, "deletes files recursively"),
            (#"(^|[;&|\s])rm\s+.*(\s/|\s~|\s\*|\s\.\.?/?)(\s|$)"#, "deletes broad paths"),
            (#"(^|[;&|\s])rm\s+.*\*"#, "deletes files by wildcard"),
            (#"git\s+push\b.*(\s--force\b|\s-f\b|\s--force-with-lease\b)"#, "force-pushes"),
            (#"git\s+push\b"#, "pushes to a remote"),
            (#"git\s+reset\s+--hard"#, "discards uncommitted work (git reset --hard)"),
            (#"git\s+clean\s+-[a-z]*f"#, "deletes untracked files (git clean)"),
            (#"git\s+checkout\s+(--\s+)?\.(\s|$)"#, "discards working-tree changes"),
            (#"git\s+restore\s+(--\S+\s+)*\.(\s|$)"#, "discards working-tree changes"),
            (#"git\s+branch\s+-d\s"#, "deletes a branch"),
            (#"git\s+stash\s+(drop|clear)"#, "drops stashed work"),
            (#"(^|\s)mkfs"#, "formats a disk"),
            (#"(^|\s)dd\s+.*of="#, "writes raw disk data"),
            (#"diskutil\s+(erase|partition|unmount)"#, "changes disks"),
            (#":\(\)\s*\{"#, "fork bomb"),
            (#"(chmod|chown)\s+-r"#, "changes permissions recursively"),
            (#"(curl|wget)\s[^|]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#, "pipes a download into a shell"),
            (#"(^|[;&|\s])(shutdown|reboot|halt)(\s|$)"#, "shuts down the Mac"),
            (#"(^|[;&|\s])(killall|pkill)\s"#, "kills processes by name"),
            (#"launchctl\s+(unload|remove|bootout)"#, "changes system services"),
            (#"(npm|yarn|pnpm|cargo|gem|twine)\s+publish"#, "publishes a package"),
            (#"drop\s+(table|database|schema)"#, "drops database objects"),
            (#">\s*/dev/(disk|sd)"#, "writes to a raw device"),
            (#"(^|\s)find\s.*\s-delete"#, "deletes files with find"),
            (#"security\s+(delete|add|find)-"#, "touches the Keychain"),
        ]
        for (pattern, reason) in rules where c.range(of: pattern, options: .regularExpression) != nil { return reason }
        return nil
    }

    /// Commands that only read, safe to run in every mode.
    static func isReadOnly(_ command: String) -> Bool {
        var cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return false }
        // fd duplication (2>&1) and discarding output are harmless; any other redirection writes a file.
        cmd = cmd.replacingOccurrences(of: #"[0-9]*>&[0-9]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[0-9]*>{1,2}\s*/dev/null"#, with: "", options: .regularExpression)
        if cmd.contains(">") { return false }
        if cmd.contains("$(") || cmd.contains("`") { return false }
        let segments = cmd.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let simple: Set<String> = ["ls", "cat", "head", "tail", "wc", "pwd", "echo", "grep", "rg", "which", "tree", "file", "stat", "du", "df",
                                   "whoami", "date", "uname", "printenv", "basename", "dirname", "realpath", "sort", "uniq", "cut", "diff", "less", "true",
                                   "type", "command", "jq", "md5", "shasum", "nl", "column", "tr", "ag", "fd"]
        for seg in segments {
            let words = seg.split(separator: " ").map(String.init)
            guard var first = words.first else { continue }
            if first == "cd" { continue }
            if first.hasPrefix("./") || first.contains("=") { return false }
            first = (first as NSString).lastPathComponent
            if simple.contains(first) { continue }
            if first == "sed" { if words.contains(where: { $0.hasPrefix("-i") }) { return false }; continue }
            if first == "find" { if words.contains(where: { ["-delete", "-exec", "-execdir", "-ok"].contains($0) }) { return false }; continue }
            if first == "git" {
                let sub = words.dropFirst().first { !$0.hasPrefix("-") } ?? ""
                let readGit: Set<String> = ["status", "diff", "log", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "remote", "config", "grep", "reflog", "ls-tree", "cat-file"]
                if readGit.contains(sub) {
                    if sub == "config" && !words.contains("--get") && !words.contains("--list") && !words.contains("-l") { return false }
                    if sub == "remote" && words.count > 2 && words[2] != "-v" { return false }
                    continue
                }
                if sub == "branch" && words.allSatisfy({ !["-d", "-D", "-m", "-M", "--delete", "--move"].contains($0) }) && words.count <= 3 { continue }
                return false
            }
            return false
        }
        return true
    }

    /// The part of a command the owner can allow for the rest of the session ("npm test", "swift build", "make").
    static func commandKey(_ command: String) -> String {
        let first = command.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).first?.trimmingCharacters(in: .whitespaces) ?? command
        let words = first.split(separator: " ").map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
        guard let tool = words.first else { return command }
        let twoWord: Set<String> = ["npm", "npx", "yarn", "pnpm", "bun", "git", "swift", "cargo", "go", "make", "python", "python3", "uv", "pip", "pip3",
                                    "docker", "xcodebuild", "dotnet", "mvn", "gradle", "./gradlew", "bundle", "rails", "mix", "deno", "node", "pytest"]
        // `python3 -m pytest`, `node --test`: the module or mode is what matters.
        if ["python", "python3", "node", "deno", "uv"].contains(tool), words.count > 2, words[1] == "-m" { return "\(tool) -m \(words[2])" }
        if twoWord.contains(tool), words.count > 1, !words[1].hasPrefix("-") {
            if ["npm", "yarn", "pnpm", "bun"].contains(tool) && words[1] == "run" && words.count > 2 { return "\(tool) run \(words[2])" }
            return "\(tool) \(words[1])"
        }
        // Interpreters with only flags (python3 -c ..., node -e ...) are allowed per exact command, never wholesale.
        if ["python", "python3", "node", "ruby", "perl", "bash", "sh", "zsh", "deno", "bun"].contains(tool) { return Fmt.line(first, 80) }
        return tool
    }
}
