import Foundation
#if !os(Windows)
import Dispatch
#endif

/// The interactive session (`anvil` in a terminal): one event loop, the way TUIDemo drives the kit. Keys, ticks,
/// resizes, the end of a run and SIGTERM all arrive as events; the terminal is restored on every exit path.
@MainActor
enum Interactive {
    static func run(_ options: CLIOptions) async -> Int32 {
        let root = HeadlessRun.projectRoot(options.project)
        guard FileManager.default.fileExists(atPath: root.path) else {
            ConfigCommand.err("anvil: project folder not found: \(root.path)")
            return ExitCode.usage
        }

        // Session: a new one, or the one --resume / --continue names.
        var session: Session
        var resumed = false
        if let id = options.resume {
            guard let full = SessionLookup.find(id, root: root), let s = SessionStore.load(full, root: root) else {
                ConfigCommand.err("anvil: no session starts with \(id) in this project. See `anvil sessions`.")
                return ExitCode.usage
            }
            session = s
            resumed = true
        } else if options.continueLast, let latest = SessionStore.list(root: root).first, let s = SessionStore.load(latest.id, root: root) {
            session = s
            resumed = true
        } else {
            session = Session(projectPath: root.path)
        }
        if let m = options.model { session.model = m }

        // No provider: the same hint as headless, before the terminal changes.
        do {
            _ = try Brain.fromSettings(model: session.model)
        } catch let e as BrainError where e.code == "no_key" {
            ConfigCommand.err(HeadlessRun.noProviderHint(e.message))
            return ExitCode.usage
        } catch {
            ConfigCommand.err((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return ExitCode.usage
        }

        let term = TUITerminal()
        guard term.isInputTTY else {
            ConfigCommand.err("anvil: the interactive session needs a terminal. Use anvil -p \"...\" instead.")
            return ExitCode.usage
        }
        guard term.enterRawMode() else {
            ConfigCommand.err("anvil: could not switch the terminal to raw mode.")
            return ExitCode.usage
        }
        defer { term.restore() }

        let live = LiveScreen(interactive: true, write: { term.write($0) }, size: { term.size() })
        let (events, continuation) = AsyncStream.makeStream(of: InteractiveEvent.self)
        let app = InteractiveSession(term: term, live: live, root: root, options: options, session: session, events: continuation)

        term.onResize = { continuation.yield(.resize) }
        let keyTask = Task {
            for await key in term.keys() { continuation.yield(.key(key)) }
        }
        let tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continuation.yield(.tick)
            }
        }
        let stopTerm = installTermSignal { continuation.yield(.quit) }

        app.start(resumed: resumed)

        loop: for await event in events {
            switch event {
            case .key(let key):
                if !app.handle(key) { break loop }
            case .tick:
                app.tick()
            case .resize:
                live.resized()
                app.redraw()
            case .runFinished(let outcome):
                app.finishRun(outcome)
            case .quit:
                break loop
            }
        }

        keyTask.cancel()
        tickTask.cancel()
        stopTerm()
        app.shutdown()
        return ExitCode.done
    }

    /// SIGTERM ends the session like Ctrl-D (raw mode turns Ctrl-C into a key, so SIGINT does not reach us).
    /// Returns the function that removes the handler.
    static func installTermSignal(_ onTerm: @escaping @Sendable () -> Void) -> () -> Void {
#if os(Windows)
        return {}
#else
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { onTerm() }
        source.resume()
        return {
            source.cancel()
            signal(SIGTERM, SIG_DFL)
        }
#endif
    }
}
