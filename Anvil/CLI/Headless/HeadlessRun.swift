import Foundation
#if !os(Windows)
import Dispatch
#endif

/// `anvil -p "..."`: one request, no UI. Ports the logic of App/Headless.swift without AppKit or the browser.
enum HeadlessRun {
    /// What the interrupt handler and the timeout timer reach.
    @MainActor
    final class Control {
        var interrupts = 0
        var timedOut = false
        var work: Task<AgentOutcome, Never>?
        let processes: ProcessManager

        init(processes: ProcessManager) { self.processes = processes }

        /// First Ctrl-C asks the agent to stop (and the session is still saved). A second one quits at once.
        func interrupt() {
            interrupts += 1
            if interrupts == 1 {
                HeadlessHost.stderr("stopping... press Ctrl-C again to quit now.")
                work?.cancel()
            } else {
                HeadlessRun.stopEverything(processes)
                _exit(130)
            }
        }
    }

    static func run(_ options: CLIOptions, prompt: String) async -> Int32 {
        let host = HeadlessHost(format: options.output, quiet: options.quiet, approve: options.approve)
        let root = projectRoot(options.project)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return early(options, host: host, root: root, reason: "usage", code: ExitCode.usage,
                         message: "project folder not found: \(root.path)")
        }

        // The session: a new one, or the one --resume / --continue names.
        var session: Session
        if let id = options.resume {
            guard let full = SessionLookup.find(id, root: root), let s = SessionStore.load(full, root: root) else {
                return early(options, host: host, root: root, reason: "usage", code: ExitCode.usage,
                             message: "no session starts with \(id) in this project. See `anvil sessions`.")
            }
            session = s
        } else if options.continueLast {
            if let latest = SessionStore.list(root: root).first, let s = SessionStore.load(latest.id, root: root) {
                session = s
            } else {
                host.progress("No earlier session in this project; starting a new one.")
                session = Session(projectPath: root.path)
            }
        } else {
            session = Session(projectPath: root.path)
        }
        if session.items.isEmpty { session.title = Session.title(from: prompt) }
        if let m = options.model { session.model = m }

        let brain: Brain
        do {
            brain = try Brain.fromSettings(model: session.model)
        } catch let e as BrainError where e.code == "no_key" {
            return early(options, host: host, root: root, reason: "no_provider", code: ExitCode.usage,
                         message: noProviderHint(e.message))
        } catch {
            return early(options, host: host, root: root, reason: "no_provider", code: ExitCode.usage,
                         message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        await ModelCatalog.shared.refresh()

        let mode = Self.permissionMode(options.mode ?? ConfigCommand.modeName(AppSettings.shared.defaultMode))
        let settings = AppSettings.shared
        let processes = ProcessManager()
        let control = Control(processes: processes)
        let ctx = ToolContext(root: root, processes: processes, host: host)
        ctx.shellTimeout = settings.shellTimeout
        MCPManager.shared.start(project: root)

        let agent = Agent(ctx: ctx, brain: brain)
        AgentSetup.configure(agent, options: options, mode: mode)
        agent.messages = session.messages
        agent.briefing = session.briefing

        // Usage: the session keeps the running total; the summary reports this run only.
        var usage = session.usage
        var spent = SessionUsage()
        brain.onUsage = { u, model, cost in
            usage.add(u, cost: cost)
            spent.add(u, cost: cost)
            host.progress("   · \(model): \(u.prompt) in (\(u.cached) cached), \(u.completion) out, \(cost.map(Fmt.dollars) ?? "?")")
        }
        var checkpoints = session.checkpoints
        agent.onCheckpoint = { cp in
            if let i = checkpoints.firstIndex(where: { $0.id == cp.id }) { checkpoints[i] = cp } else { checkpoints.append(cp) }
        }

        host.items.append(ChatItem(kind: .user, text: prompt))
        host.progress("▶︎ \(prompt)\n  project: \(root.path), mode: \(mode.label), model: \(brain.model) (\(Providers.label(for: brain.model))), effort: \(brain.effort)")

        let start = Date()
        let stopInterrupt = installInterrupt(control)
        let work = Task { await agent.run(goal: prompt) }
        control.work = work
        var timer: Task<Void, Never>?
        if let t = options.timeout {
            timer = Task {
                try? await Task.sleep(for: .seconds(t))
                if !Task.isCancelled {
                    control.timedOut = true
                    control.work?.cancel()
                }
            }
        }
        let outcome = await work.value
        timer?.cancel()
        stopInterrupt()
        stopEverything(processes)

        session.items += host.items
        session.messages = agent.messages
        session.briefing = agent.briefing
        session.checkpoints = checkpoints
        session.usage = usage
        session.todos = ctx.todos
        session.updated = Date()   // the list sorts by this, so --continue picks the run just finished
        do {
            try SessionStore.save(session)
        } catch {
            HeadlessHost.stderr("warning: the session could not be saved: \(error.localizedDescription)")
        }

        let interrupted = control.interrupts > 0
        let reason = HeadlessExit.reason(ok: outcome.ok, interrupted: interrupted, timedOut: control.timedOut,
                                         failure: host.failure, steps: outcome.steps, maxSteps: agent.maxSteps,
                                         costLimit: agent.maxCost, spent: spent.cost, missing: outcome.missing)
        let summary = HeadlessSummary(
            ok: outcome.ok, answer: outcome.text, exitReason: reason, steps: outcome.steps,
            seconds: Date().timeIntervalSince(start), cost: spent.cost, calls: spent.calls,
            prompt: spent.prompt, completion: spent.completion, cached: spent.cached, model: brain.model,
            changed: outcome.changedFiles, session: session.id.uuidString, verified: outcome.verifiedBy ?? "")
        let code = HeadlessExit.code(reason: reason)
        report(summary, format: options.output, quiet: options.quiet,
               status: interrupted ? "stopped" : outcome.ok ? "done" : "stopped",
               detail: "in \(outcome.steps) steps, \(Int(summary.seconds))s, \(Fmt.dollars(spent.cost)) (\(spent.calls) calls)",
               changed: outcome.changedFiles, session: session.id.uuidString,
               failure: host.failureText)
        return code
    }

    /// Prints the result in the requested format: text (answer on stdout, status on stderr), one JSON object, or
    /// the final stream-json line.
    static func report(_ s: HeadlessSummary, format: OutputFormat, quiet: Bool, status: String, detail: String,
                       changed: [String], session: String, failure: String?) {
        switch format {
        case .text:
            // A provider or setup failure is an error, not an answer: the host already printed it on stderr
            // (unless --quiet), so stdout stays empty and `> answer.txt` captures nothing wrong.
            let failed = s.exitReason == "provider" || s.exitReason == "no_provider"
            if failed {
                if quiet && !s.answer.isEmpty { HeadlessHost.stderr(s.answer) }
            } else if !s.answer.isEmpty {
                print(s.answer)
            }
            if !quiet {
                HeadlessHost.stderr("\n■ \(status) \(detail)")
                if !changed.isEmpty { HeadlessHost.stderr("  changed: \(changed.joined(separator: ", "))") }
                HeadlessHost.stderr("  session: \(session)")
            }
        case .json, .streamJSON:
            print(resultLine(s, format: format))
            if !quiet { HeadlessHost.stderr("■ \(status) \(detail)") }
        }
    }

    /// The JSON result object as one line: the whole output for --output json, the last line for stream-json.
    static func resultLine(_ s: HeadlessSummary, format: OutputFormat) -> String {
        var o = s.object
        if format == .streamJSON { o["type"] = "result" }
        return JSONLine.encode(o)
    }

    /// A run that never reached the agent (bad project, no provider, unknown session). Same output contract as a run.
    static func early(_ options: CLIOptions, host: HeadlessHost, root: URL, reason: String, code: Int32, message: String) -> Int32 {
        let summary = HeadlessSummary(ok: false, answer: "", exitReason: reason, steps: 0, seconds: 0, cost: 0, calls: 0,
                                      prompt: 0, completion: 0, cached: 0, model: AppSettings.shared.model, changed: [],
                                      session: "", verified: "")
        HeadlessHost.stderr(message)
        MCPManager.shared.stopAll()
        ProviderServers.shared.stopAll()
        if options.output != .text { report(summary, format: options.output, quiet: true, status: "", detail: "", changed: [], session: "", failure: message) }
        return code
    }

    static func noProviderHint(_ detail: String) -> String {
        var lines = ["No model provider is set up yet."]
        if !detail.isEmpty { lines.append(detail) }
        lines.append("Add a preset:  anvil providers presets, then anvil providers add PRESET_ID")
        lines.append("Or store the Experiential Labs key:  anvil config set api-key")
        return lines.joined(separator: "\n")
    }

    static func permissionMode(_ name: String) -> PermissionMode {
        switch name {
        case "edits": return .acceptEdits
        case "plan": return .plan
        case "bypass": return .bypass
        default: return .ask
        }
    }

    static func projectRoot(_ raw: String?) -> URL {
        let path = raw.map { NSString(string: $0).expandingTildeInPath } ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Stops every background thing a run may have started. Called on every exit path.
    static func stopEverything(_ processes: ProcessManager) {
        processes.stopAll()
        MCPManager.shared.stopAll()
        ProviderServers.shared.stopAll()
    }

    /// Ctrl-C goes to `control` instead of killing the process. Returns the function that removes the handler.
    static func installInterrupt(_ control: Control) -> () -> Void {
#if os(Windows)
        return {}
#else
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { control.interrupt() } }
        source.resume()
        return {
            source.cancel()
            signal(SIGINT, SIG_DFL)
        }
#endif
    }
}
