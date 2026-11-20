import Foundation

/// Shell commands, background processes and waiting on real conditions.
enum ShellTools {
    static func all() -> [ToolSpec] { [shell, startProcess, readProcess, stopProcess, listProcesses, waitUntil, wait] }

    /// Commands that never finish on their own (servers, watchers). They belong in start_process.
    static func looksLikeServer(_ command: String) -> Bool {
        let c = command.lowercased()
        if c.contains("&") && c.trimmingCharacters(in: .whitespaces).hasSuffix("&") { return true }
        let patterns = [#"\bnpm (run )?(dev|start|serve|watch)\b"#, #"\b(yarn|pnpm|bun)( run)? (dev|start|serve|watch)\b"#, #"\bnext dev\b"#, #"\bvite( |$)(?!build)"#,
                        #"python3? -m http\.server"#, #"\bflask run\b"#, #"\buvicorn\b"#, #"\bmanage\.py runserver\b"#, #"\brails (s|server)\b"#,
                        #"\bnodemon\b"#, #"\bwebpack serve\b"#, #"\bjekyll serve\b"#, #"\bhugo server\b"#, #"--watch\b"#, #"\btail -f\b"#, #"\bphp -S\b"#, #"\bhttp-server\b"#, #"\bserve -s\b"#]
        return patterns.contains { c.range(of: $0, options: .regularExpression) != nil }
    }

    static let shell = ToolSpec(
        name: "shell", kind: .exec,
        signature: #"{"command": str, optional "timeout": seconds (default 300), "cwd": subfolder}"#,
        summary: "run a zsh command in the project root and wait for it (build, test, git, install). Non-interactive: no prompts, editors or pagers",
        group: .shell,
        command: { $0["command"]?.string ?? $0["cmd"]?.string ?? $0["value"]?.string }
    ) { a, ctx in
        guard let cmd = a["command"]?.string ?? a["cmd"]?.string ?? a["value"]?.string, !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return .fail("missing command") }
        if looksLikeServer(cmd) && a["force"]?.bool != true {
            return .fail("this looks like a long-running server or watcher, which would block until the timeout. Use start_process instead, then wait_until (url/port/output) and read_process. Pass \"force\": true if it really exits on its own.")
        }
        let cwd = a["cwd"]?.string.map(ctx.resolve) ?? ctx.root
        let timeout = max(1, min(1800, a["timeout"]?.double ?? ctx.shellTimeout))
        let stepID = ctx.stepID
        weak var host = ctx.host
        let start = Date()
        let r = await ProcessRunner.shell(cmd, cwd: cwd, timeout: timeout) { chunk in
            Task { @MainActor in if let stepID { host?.agentStepOutput(stepID, chunk: chunk) } }
        }
        var out = r.combined
        if out.isEmpty { out = "(no output)" }
        let secs = Date().timeIntervalSince(start)
        let header = "exit \(r.status)" + (secs >= 2 ? String(format: " in %.1fs", secs) : "") + (r.timedOut ? " (timed out after \(Int(timeout))s and was stopped)" : "")
        var res = ToolResult(ok: r.status == 0 && !r.timedOut, output: header + "\n" + Fmt.clip(out, max: 14000))
        res.stopBatch = !res.ok
        return res
    }

    static func defaultName(_ command: String) -> String {
        let words = command.split(separator: " ").map(String.init).filter { !$0.hasPrefix("-") && !$0.contains("=") }
        return SkillLibrary.slug(words.prefix(3).joined(separator: " ")).prefix(30).description
    }

    static let startProcess = ToolSpec(
        name: "start_process", kind: .exec,
        signature: #"{"command": str, optional "name": short id, "cwd": subfolder}"#,
        summary: "start a long-running command in the background (dev server, watcher); returns its first output. Then wait_until and read_process",
        group: .shell,
        command: { $0["command"]?.string ?? $0["value"]?.string }
    ) { a, ctx in
        guard let cmd = a["command"]?.string ?? a["value"]?.string else { return .fail("missing command") }
        let name = a["name"]?.string ?? defaultName(cmd)
        let cwd = a["cwd"]?.string.map(ctx.resolve) ?? ctx.root
        let e = try ctx.processes.start(name: name, command: cmd, cwd: cwd)
        try? await Task.sleep(for: .seconds(2))
        let early = e.output.value
        if let code = e.exitCode {
            return .fail("\(name) exited right away with code \(code):\n" + Fmt.clip(early, max: 6000))
        }
        return .ok("started \(name) (pid \(e.process.processIdentifier)). Output so far:\n" + (early.isEmpty ? "(none yet)" : Fmt.clip(early, max: 4000)))
    }

    static let readProcess = ToolSpec(
        name: "read_process", kind: .read,
        signature: #"{"name": str, optional "tail": lines (default 60)}"#,
        summary: "recent output of a background process and whether it is still running",
        group: .shell
    ) { a, ctx in
        guard let name = a["name"]?.string ?? a["value"]?.string else { return .fail("missing name") }
        guard let e = ctx.processes.entry(name) else { return .fail("no process named \(name). Running: \(ctx.processes.entries.map(\.name).joined(separator: ", "))") }
        let n = max(1, min(400, a["tail"]?.int ?? 60))
        let lines = e.output.value.components(separatedBy: "\n").suffix(n).joined(separator: "\n")
        let state = e.running ? "running" : "exited with code \(e.exitCode ?? -1)"
        return .ok("\(name): \(state)\n" + Fmt.clip(lines, max: 10000))
    }

    static let stopProcess = ToolSpec(
        name: "stop_process", kind: .meta,
        signature: #"{"name": str}"#,
        summary: "stop a background process (and its children)",
        group: .shell
    ) { a, ctx in
        guard let name = a["name"]?.string ?? a["value"]?.string else { return .fail("missing name") }
        return ctx.processes.stop(name) ? .ok("stopped \(name)") : .fail("no running process named \(name)")
    }

    static let listProcesses = ToolSpec(
        name: "list_processes", kind: .read, signature: "{}",
        summary: "background processes and their state",
        group: .shell
    ) { _, ctx in
        let l = ctx.processes.entries
        return .ok(l.isEmpty ? "no background processes" : l.map { "- \($0.name): \($0.running ? "running" : "exited \($0.exitCode ?? -1)"): \($0.command)" }.joined(separator: "\n"))
    }

    static let kinds = ["url", "port", "file", "output", "process_exits", "command"]

    static let waitUntil = ToolSpec(
        name: "wait_until", kind: .read,
        signature: #"{"until": "url|port|file|output|process_exits|command", "value": str, optional "name": background process (for output/process_exits), "timeout": seconds (default 60)}"#,
        summary: "wait for a real condition: a URL responds, a port accepts connections, a file exists, text appears in a background process's output, it exits, or a command succeeds",
        group: .shell,
        command: { $0["until"]?.string == "command" ? $0["value"]?.string : nil },
        kindFor: { $0["until"]?.string == "command" ? .exec : .read }
    ) { a, ctx in
        guard let kind = a["until"]?.string?.lowercased(), kinds.contains(kind) else { return .fail("until must be one of: \(kinds.joined(separator: ", "))") }
        let value = a["value"]?.string ?? a["text"]?.string ?? a["url"]?.string ?? ""
        let timeout = max(1, min(900, a["timeout"]?.double ?? 60))
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            try Task.checkCancellation()
            var met = false
            switch kind {
            case "url":
                if let u = URL(string: value.contains("://") ? value : "http://" + value) {
                    var req = URLRequest(url: u); req.timeoutInterval = 3
                    let status = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                    met = status > 0 && status < 500
                }
            case "port":
                if let port = Int(value.split(separator: ":").last ?? "") {
                    met = await ProcessRunner.run("/usr/bin/nc", ["-z", "127.0.0.1", "\(port)"], timeout: 3).status == 0
                }
            case "file":
                met = FileManager.default.fileExists(atPath: ctx.resolve(value).path)
            case "output":
                guard let name = a["name"]?.string, let e = ctx.processes.entry(name) else { return .fail("output needs the name of a background process") }
                if e.output.value.localizedCaseInsensitiveContains(value) { met = true }
                else if !e.running { return .fail("\(name) exited (code \(e.exitCode ?? -1)) before printing \"\(value)\". Last output:\n" + Fmt.clip(String(e.output.value.suffix(3000)), max: 3000)) }
            case "process_exits":
                guard let name = a["name"]?.string ?? (value.isEmpty ? nil : value), let e = ctx.processes.entry(name) else { return .fail("process_exits needs a background process name") }
                met = !e.running
            case "command":
                met = await ProcessRunner.shell(value, cwd: ctx.root, timeout: 30).status == 0
            default: break
            }
            if met { return .ok("condition met after \(Int(Date().timeIntervalSince(start)))s (\(kind): \(Fmt.line(value, 80)))") }
            try await Task.sleep(for: .seconds(kind == "command" ? 2 : 1))
        }
        return .fail("still not \(kind) \"\(Fmt.line(value, 80))\" after \(Int(timeout))s. Check read_process for errors, or wait longer if it is clearly progressing.")
    }

    static let wait = ToolSpec(
        name: "wait", kind: .meta,
        signature: #"{"seconds": num (max 60)}"#,
        summary: "pause briefly; prefer wait_until",
        group: .shell
    ) { a, _ in
        let s = max(0.1, min(60, a["seconds"]?.double ?? a["value"]?.double ?? 2))
        try await Task.sleep(for: .seconds(s))
        return .ok("waited \(s)s")
    }
}
