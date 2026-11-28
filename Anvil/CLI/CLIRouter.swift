import Foundation

/// Parses the top-level command line and dispatches it.
///   anvil                     the interactive session (in a terminal)
///   anvil -p "PROMPT"         one request, headless (also: echo PROMPT | anvil)
///   anvil config|providers|models|sessions ...
///   anvil --version, --help
enum CLIRouter {
    static let version = "0.1.0"
    static let commands = ["config", "providers", "models", "sessions", "version", "help", "tui-demo"]

    static func run(_ args: [String]) async -> Int32 {
        let opts: CLIOptions
        do {
            opts = try CLIOptions.parse(args)
        } catch let e as OptionError {
            ConfigCommand.err("anvil: \(e.message)")
            return ExitCode.usage
        } catch {
            ConfigCommand.err("anvil: \(error.localizedDescription)")
            return ExitCode.usage
        }

        if opts.version || opts.positionals.first == "version" {
            print("anvil \(version)")
            return ExitCode.done
        }
        if opts.help {
            print(opts.positionals.first.flatMap(Help.command) ?? Help.main)
            return ExitCode.done
        }
        if opts.wantsPrint {
            return await headless(opts)
        }
        guard let command = opts.positionals.first else {
            // No command and no -p: a terminal gets the interactive session; a pipe gets its text as the prompt.
            if Terminal.stdinIsTTY { return await Interactive.run(opts) }
            var piped = opts
            piped.promptFromStdin = true
            return await headless(piped)
        }

        let rest = Array(opts.positionals.dropFirst())
        switch command {
        case "config":
            return ConfigCommand.run(rest)
        case "providers", "provider":
            return await ProvidersCommand.run(rest)
        case "models":
            return ProvidersCommand.models()
        case "sessions":
            return SessionsCommand.run(opts)
        case "tui-demo":
            return await TUIDemo.run()
        case "help":
            print(rest.first.flatMap(Help.command) ?? Help.main)
            return ExitCode.done
        default:
            ConfigCommand.err(unknownCommand(command))
            return ExitCode.usage
        }
    }

    /// Reads the prompt (from -p, the words after it, or stdin) and runs it headless.
    static func headless(_ opts: CLIOptions) async -> Int32 {
        var parts: [String] = []
        if let p = opts.prompt { parts.append(p) }
        var prompt = ""
        if opts.promptFromStdin {
            if Terminal.stdinIsTTY {
                ConfigCommand.err("Type the prompt, then press Ctrl-D.")
            }
            let piped = Terminal.readAllStdin().trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = ([opts.positionals.joined(separator: " ")] + [piped]).filter { !$0.isEmpty }.joined(separator: "\n\n")
        } else {
            // Words that follow -p without quotes belong to the prompt.
            prompt = (parts + opts.positionals).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !prompt.isEmpty else {
            ConfigCommand.err("anvil: no prompt given. Usage: anvil -p \"PROMPT\"  (or pipe the prompt in: echo \"...\" | anvil)")
            return ExitCode.usage
        }
        return await HeadlessRun.run(opts, prompt: prompt)
    }

    /// The message for an unknown command, with the closest command name when it is near enough.
    static func unknownCommand(_ word: String) -> String {
        var msg = "unknown command \"\(word)\"."
        if let best = commands.min(by: { OptionParser.distance($0, word) < OptionParser.distance($1, word) }),
           OptionParser.distance(best, word) <= 2 {
            msg += " Did you mean \(best)?"
        }
        return msg + " To send a request, use: anvil -p \"...\". Run `anvil --help` for the list."
    }
}
