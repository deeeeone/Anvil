import Foundation

/// `anvil providers` and `anvil models`: the model providers, their presets, and the models they offer.
enum ProvidersCommand {
    static func run(_ args: [String]) async -> Int32 {
        guard let sub = args.first else { return list() }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list", "ls": return list()
        case "presets": return presets()
        case "add": return add(rest)
        case "key": return key(rest)
        case "remove", "rm": return remove(rest)
        case "help", "--help", "-h": print(Help.providers); return ExitCode.done
        default:
            ConfigCommand.err("anvil providers: unknown subcommand \"\(sub)\". Use list, presets, add, key or remove.")
            return ExitCode.usage
        }
    }

    static func list() -> Int32 {
        print("Built in:")
        let builtIn: [(Provider, String)] = [
            (.experiential, AppSettings.shared.hasKey ? "ready" : "not set up: anvil config set api-key"),
            (.luna, AppSettings.shared.ready(.luna) ? "ready" : "not set up: set luna-url in Settings"),
            (.gemini, AppSettings.shared.ready(.gemini) ? "ready" : "not set up: sign in from the Mac app"),
            (.chatgpt, AppSettings.shared.ready(.chatgpt) ? "ready" : "not set up: sign in from the Mac app"),
        ]
        for (p, state) in builtIn {
            print("  " + p.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0) + p.label.padding(toLength: 22, withPad: " ", startingAt: 0) + state)
        }
        let plugins = ProviderPlugins.shared.installed
        print("")
        if plugins.isEmpty {
            print("Plugins: none installed. See `anvil providers presets`.")
        } else {
            print("Plugins:")
            for p in plugins {
                print("  " + p.id.padding(toLength: 14, withPad: " ", startingAt: 0) + p.spec.name.padding(toLength: 22, withPad: " ", startingAt: 0) + pluginState(p))
            }
        }
        for (id, problem) in ProviderPlugins.shared.problems.sorted(by: { $0.key < $1.key }) {
            print("  \(id): problem: \(problem)")
        }
        return ExitCode.done
    }

    static func pluginState(_ p: InstalledProvider) -> String {
        if ProviderPlugins.shared.isReady(p.id) { return "ready" }
        switch p.spec.auth.type {
        case .apiKey: return "needs an API key: anvil providers key \(p.id)"
        case .web: return "not signed in: sign in from the Mac app"
        case .none: return "not ready"
        }
    }

    static func presets() -> Int32 {
        let installed = Set(ProviderPlugins.shared.installed.map(\.id))
        let list = ProviderPlugins.presets
        if list.isEmpty { print("No presets are bundled in this build."); return ExitCode.done }
        for s in list {
            let tag = installed.contains(s.id) ? " (installed)" : ""
            let needs = s.auth.type == .apiKey ? "API key" : s.auth.type == .web ? "web sign-in" : "no key"
            print("  \(s.id)\(tag)")
            print("      \(s.name), \(needs)" + (s.description.map { " - \($0)" } ?? ""))
        }
        print("\nAdd one with: anvil providers add PRESET_ID")
        return ExitCode.done
    }

    static func add(_ args: [String]) -> Int32 {
        guard let id = args.first?.lowercased() else { ConfigCommand.err("anvil providers add: give a preset id. See `anvil providers presets`."); return ExitCode.usage }
        let presets = ProviderPlugins.presets
        guard let spec = presets.first(where: { $0.id.lowercased() == id }) else {
            let near = presets.map(\.id).min { OptionParser.distance($0, id) < OptionParser.distance($1, id) }
            var msg = "no preset called \"\(id)\"."
            if let near, OptionParser.distance(near, id) <= 3 { msg += " Did you mean \(near)?" }
            ConfigCommand.err("anvil providers add: " + msg + " See `anvil providers presets`.")
            return ExitCode.usage
        }
        if ProviderPlugins.shared.provider(spec.id) == nil {
            do {
                try ProviderPlugins.shared.add(preset: spec)
            } catch {
                ConfigCommand.err("anvil providers add: could not install \(spec.id): \(error.localizedDescription)")
                return ExitCode.usage
            }
            print("Added \(spec.name).")
        } else {
            print("\(spec.name) is already installed.")
        }
        guard let installed = ProviderPlugins.shared.provider(spec.id) else { return ExitCode.usage }
        switch spec.auth.type {
        case .apiKey where spec.auth.optional != true:
            if ProviderPlugins.shared.isReady(spec.id) { print("API key already set."); return ExitCode.done }
            if let url = spec.auth.keyURL { print("Get a key at \(url)") }
            return storeKey(for: installed, prompt: "\(spec.name) API key (input is hidden): ")
        case .web:
            print("Sign in to \(spec.name) from the Mac app (Settings → Provider). The CLI cannot do the browser sign-in yet.")
            return ExitCode.done
        default:
            print("Ready: pick it with --model \(spec.id)/MODEL (see `anvil models`).")
            return ExitCode.done
        }
    }

    static func key(_ args: [String]) -> Int32 {
        guard let id = args.first else { ConfigCommand.err("anvil providers key: give a plugin id. See `anvil providers`."); return ExitCode.usage }
        guard let p = ProviderPlugins.shared.provider(id) else {
            ConfigCommand.err("anvil providers key: no plugin called \"\(id)\". See `anvil providers`.")
            return ExitCode.usage
        }
        guard p.spec.auth.type == .apiKey else {
            ConfigCommand.err("anvil providers key: \(p.spec.name) does not take an API key.")
            return ExitCode.usage
        }
        return storeKey(for: p, prompt: "\(p.spec.name) API key (input is hidden): ")
    }

    /// Reads a key without echo (or from a pipe) and stores it on the plugin. Never prints it.
    static func storeKey(for p: InstalledProvider, prompt: String) -> Int32 {
        if Terminal.stdinIsTTY {
            FileHandle.standardError.write(Data(prompt.utf8))
        }
        let raw = Terminal.readSecret(prompt: "") ?? ""
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            ConfigCommand.err("No key given. Run `anvil providers key \(p.id)` to add it later.")
            return ExitCode.usage
        }
        ProviderPlugins.shared.setAPIKey(p.id, key)
        guard ProviderPlugins.shared.apiKey(p.id) == key else {
            ConfigCommand.err("The key could not be saved to the keychain. Nothing was stored.")
            return ExitCode.usage
        }
        print("Saved the \(p.spec.name) key.")
        return ExitCode.done
    }

    static func remove(_ args: [String]) -> Int32 {
        guard let id = args.first else { ConfigCommand.err("anvil providers remove: give a plugin id."); return ExitCode.usage }
        guard let p = ProviderPlugins.shared.provider(id) else {
            ConfigCommand.err("anvil providers remove: no plugin called \"\(id)\".")
            return ExitCode.usage
        }
        ProviderPlugins.shared.remove(p.id)
        print("Removed \(p.spec.name), and its key.")
        return ExitCode.done
    }

    // MARK: models

    /// `anvil models`: what can be picked now. Reads the cached catalog only (no network).
    static func models() -> Int32 {
        let current = AppSettings.shared.model
        let choices = ModelCatalog.shared.choices
        if choices.isEmpty { print("No models are listed yet. Run a request once, or check `anvil providers`."); return ExitCode.done }
        let width = choices.map { $0.id.count }.max() ?? 0
        for c in choices {
            let mark = c.id == current ? "*" : " "
            let ready = AppSettings.shared.ready(model: c.id) ? "" : "  (not set up)"
            let label = Providers.label(for: c.id)
            let detail = c.detail.isEmpty ? "" : "  " + c.detail
            print("\(mark) " + c.id.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + label + detail + ready)
        }
        print("\n* = the default (anvil config get model). Use another with --model ID.")
        return ExitCode.done
    }
}
