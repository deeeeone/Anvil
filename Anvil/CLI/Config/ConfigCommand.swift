import Foundation

/// `anvil config`: the settings the CLI shares with the app (AppSettings), plus the API key.
enum ConfigCommand {
    /// What a setting accepts. Values are checked before they are stored.
    enum Kind {
        case bool
        case int(min: Int)
        case double(min: Double)
        case text
        case choice([String])
    }

    struct Field {
        let name: String
        let kind: Kind
        let about: String
        let get: () -> String
        let set: (String) -> Void
    }

    struct Failure: Error {
        let message: String
    }

    /// The whitelisted settings. Names are kebab-case; any spelling that normalizes to the same letters also works.
    static let fields: [Field] = [
        Field(name: "model", kind: .text, about: "model for new requests (see `anvil models`)",
              get: { AppSettings.shared.model }, set: { AppSettings.shared.model = $0 }),
        Field(name: "vision-model", kind: .text, about: "model for turns with images (empty = never send images)",
              get: { AppSettings.shared.visionModel }, set: { AppSettings.shared.visionModel = $0 }),
        Field(name: "effort", kind: .choice(AppSettings.efforts), about: "reasoning effort ceiling: low, medium, high or max",
              get: { AppSettings.shared.effort }, set: { AppSettings.shared.effort = $0 }),
        Field(name: "default-mode", kind: .choice(["ask", "edits", "plan", "bypass"]),
              about: "permission mode when none is given: ask, edits, plan or bypass",
              get: { modeName(AppSettings.shared.defaultMode) },
              set: { AppSettings.shared.defaultMode = modeValue($0) }),
        Field(name: "max-steps", kind: .int(min: 1), about: "steps before a request stops",
              get: { String(AppSettings.shared.maxSteps) }, set: { AppSettings.shared.maxSteps = Int($0) ?? 0 }),
        Field(name: "max-task-cost", kind: .double(min: 0), about: "USD a request may cost before it stops (0 = no limit)",
              get: { String(AppSettings.shared.maxTaskCost) }, set: { AppSettings.shared.maxTaskCost = Double($0) ?? 0 }),
        Field(name: "shell-timeout", kind: .double(min: 1), about: "seconds a shell command may run",
              get: { String(AppSettings.shared.shellTimeout) }, set: { AppSettings.shared.shellTimeout = Double($0) ?? 0 }),
        Field(name: "auto-compact-tokens", kind: .int(min: 1000), about: "context size (tokens) at which the session is compacted",
              get: { String(AppSettings.shared.autoCompactTokens) }, set: { AppSettings.shared.autoCompactTokens = Int($0) ?? 0 }),
        Field(name: "auto-verify", kind: .bool, about: "run the project's tests before accepting a finished request",
              get: { String(AppSettings.shared.autoVerify) }, set: { AppSettings.shared.autoVerify = $0 == "true" }),
        Field(name: "self-review", kind: .bool, about: "have a second pass read the final diff for real problems",
              get: { String(AppSettings.shared.selfReview) }, set: { AppSettings.shared.selfReview = $0 == "true" }),
        Field(name: "judge-enabled", kind: .bool, about: "check the answer against the request before it is accepted",
              get: { String(AppSettings.shared.judgeEnabled) }, set: { AppSettings.shared.judgeEnabled = $0 == "true" }),
        Field(name: "streaming", kind: .bool, about: "stream replies as they come (live text)",
              get: { String(AppSettings.shared.streaming) }, set: { AppSettings.shared.streaming = $0 == "true" }),
        Field(name: "adaptive-effort", kind: .bool, about: "lower the reasoning effort for simple turns",
              get: { String(AppSettings.shared.adaptiveEffort) }, set: { AppSettings.shared.adaptiveEffort = $0 == "true" }),
        Field(name: "base-url", kind: .text, about: "Experiential Labs API address",
              get: { AppSettings.shared.baseURL }, set: { AppSettings.shared.baseURL = $0 }),
        Field(name: "escalation-model", kind: .text, about: "model a failing action switches to (auto, empty = off, or a model id)",
              get: { AppSettings.shared.escalationModel }, set: { AppSettings.shared.escalationModel = $0 }),
        Field(name: "explore-model", kind: .text, about: "model for read-only exploration (empty = the session model)",
              get: { AppSettings.shared.exploreModel }, set: { AppSettings.shared.exploreModel = $0 }),
        Field(name: "quick-model", kind: .text, about: "model for simple requests such as renames (empty = the session model)",
              get: { AppSettings.shared.quickModel }, set: { AppSettings.shared.quickModel = $0 }),
    ]

    /// The setting a name refers to: "max-steps", "maxSteps" and "max_steps" are the same setting.
    static func field(_ name: String) -> Field? {
        let key = normalize(name)
        return fields.first { normalize($0.name) == key }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Validation (pure; the tests use these)

    /// The stored form of `raw` for a field kind, or why it is not allowed.
    static func validate(_ raw: String, for kind: Kind) throws -> String {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .bool:
            switch v.lowercased() {
            case "true", "yes", "on", "1": return "true"
            case "false", "no", "off", "0": return "false"
            default: throw Failure(message: "expected true or false, got \"\(raw)\".")
            }
        case .int(let min):
            guard let n = Int(v) else { throw Failure(message: "expected a whole number, got \"\(raw)\".") }
            guard n >= min else { throw Failure(message: "must be at least \(min), got \(n).") }
            return String(n)
        case .double(let min):
            guard let x = Double(v), x.isFinite else { throw Failure(message: "expected a number, got \"\(raw)\".") }
            guard x >= min else { throw Failure(message: "must be at least \(min), got \(x).") }
            return String(x)
        case .text:
            return v
        case .choice(let options):
            guard options.contains(v.lowercased()) else {
                throw Failure(message: "expected one of \(options.joined(separator: ", ")), got \"\(raw)\".")
            }
            return v.lowercased()
        }
    }

    /// Stores a value for a setting after checking it. Throws Failure with a readable message.
    static func set(_ name: String, to raw: String) throws {
        guard let f = field(name) else { throw Failure(message: unknownName(name)) }
        let stored = try validate(raw, for: f.kind)
        f.set(stored)
    }

    static func unknownName(_ name: String) -> String {
        var msg = "no setting called \"\(name)\"."
        let key = normalize(name)
        let names = fields.map(\.name) + ["api-key"]
        if let best = names.map({ ($0, OptionParser.distance(key, normalize($0))) }).min(by: { $0.1 < $1.1 }), best.1 <= 3 {
            msg += " Did you mean \(best.0)?"
        }
        return msg + " Run `anvil config list`."
    }

    static func modeName(_ m: PermissionMode) -> String {
        switch m {
        case .ask: return "ask"
        case .acceptEdits: return "edits"
        case .plan: return "plan"
        case .bypass: return "bypass"
        }
    }

    static func modeValue(_ s: String) -> PermissionMode {
        switch s {
        case "edits": return .acceptEdits
        case "plan": return .plan
        case "bypass": return .bypass
        default: return .ask
        }
    }

    // MARK: Commands

    static func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else { return list() }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list", "ls": return list()
        case "get": return get(rest)
        case "set": return set(rest)
        case "path": print(Paths.support.path); return ExitCode.done
        case "help", "--help", "-h": print(Help.config); return ExitCode.done
        default:
            err("anvil config: unknown subcommand \"\(sub)\". Use list, get, set or path.")
            return ExitCode.usage
        }
    }

    static func list() -> Int32 {
        let rows: [(name: String, value: String, about: String)] = fields.map { f in
            let value = f.get()
            return (f.name, value.isEmpty ? "(empty)" : value, f.about)
        } + [("api-key", AppSettings.shared.hasKey ? "set" : "not set", "Experiential Labs API key (`anvil config set api-key`)")]
        let nameWidth = rows.map { $0.name.count }.max() ?? 0
        let valueWidth = min(28, rows.map { $0.value.count }.max() ?? 0)
        print("Settings (change with `anvil config set NAME VALUE`; the CLI keeps its own copy, see `anvil config path`):")
        for r in rows {
            let value = r.value.count > valueWidth ? String(r.value.prefix(valueWidth - 1)) + "…" : r.value
            print("  " + r.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0) + "  " + value.padding(toLength: valueWidth, withPad: " ", startingAt: 0) + "  " + r.about)
        }
        return ExitCode.done
    }

    static func get(_ args: [String]) -> Int32 {
        guard let name = args.first else { err("anvil config get: give a setting name. See `anvil config list`."); return ExitCode.usage }
        if normalize(name) == "apikey" {
            print(AppSettings.shared.hasKey ? "set" : "not set")
            return ExitCode.done
        }
        guard let f = field(name) else { err("anvil config: " + unknownName(name)); return ExitCode.usage }
        print(f.get())
        return ExitCode.done
    }

    static func set(_ args: [String]) -> Int32 {
        guard let name = args.first else { err("anvil config set: give a name and a value, or `api-key` alone."); return ExitCode.usage }
        if normalize(name) == "apikey" {
            guard args.count == 1 else {
                err("anvil config set api-key: don't pass the key on the command line (it would stay in your shell history). Run `anvil config set api-key` and paste it at the prompt.")
                return ExitCode.usage
            }
            return setAPIKey()
        }
        guard args.count >= 2 else { err("anvil config set \(name): give a value. Example: anvil config set \(name) VALUE"); return ExitCode.usage }
        do {
            try set(name, to: args[1])
            print("\(field(name)?.name ?? name) = \(field(name)?.get() ?? args[1])")
            return ExitCode.done
        } catch let f as Failure {
            err("anvil config set \(name): \(f.message)")
            return ExitCode.usage
        } catch {
            err("anvil config set \(name): \(error.localizedDescription)")
            return ExitCode.usage
        }
    }

    /// Reads the API key without echo and stores it the way the app does (Keychain, or credentials.json on Linux).
    static func setAPIKey() -> Int32 {
        if ProcessInfo.processInfo.environment["ANVIL_API_KEY"]?.isEmpty == false {
            err("ANVIL_API_KEY is set in this environment, so the key comes from there and cannot be stored. Unset it, then run this again.")
            return ExitCode.usage
        }
        if Terminal.stdinIsTTY {
            FileHandle.standardError.write(Data("Paste the Experiential Labs API key (input is hidden): ".utf8))
        }
        let raw = Terminal.readSecret(prompt: "") ?? ""
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { err("No key given. Nothing was changed."); return ExitCode.usage }
        AppSettings.shared.apiKey = key
        // Read it back: a Keychain that refused the write must not look like success.
        guard Keychain.get("apiKey") == key else {
            err("The key could not be saved to the keychain. Nothing was stored.")
            return ExitCode.usage
        }
        print("Saved the API key. Check with `anvil config get api-key`.")
        return ExitCode.done
    }

    static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
