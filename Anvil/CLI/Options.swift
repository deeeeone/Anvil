import Foundation

/// Where a headless run writes its output.
nonisolated enum OutputFormat: String, Sendable {
    case text, json, streamJSON = "stream-json"
}

/// Everything the command line can say. Parsed once by `CLIOptions.parse`; commands read what they need.
nonisolated struct CLIOptions: Sendable {
    /// The prompt given with -p/--print ("-" means read it from stdin).
    var prompt: String?
    /// -p was given without a prompt, or with "-": the prompt comes from stdin.
    var promptFromStdin = false
    var project: String?
    var model: String?
    var mode: String?
    var maxSteps: Int?
    var maxCost: Double?
    var continueLast = false
    var resume: String?
    var noVerify = false
    var noReview = false
    var noJudge = false
    var noStream = false
    var timeout: Double?
    var approve = false
    var output: OutputFormat = .text
    var quiet = false
    var all = false
    var help = false
    var version = false
    /// Words that are not options, in order (the command and its arguments, or a stray prompt).
    var positionals: [String] = []

    /// True when the run should go headless: -p was given, or the prompt was piped in with no command.
    var wantsPrint: Bool { prompt != nil || promptFromStdin }
}

/// A usage error. `message` is a full sentence, with a "did you mean" hint when there is one.
nonisolated struct OptionError: Error, Equatable, Sendable {
    var message: String
}

/// Hand-written option parser: `--flag value`, `--flag=value`, short `-p VALUE`, `-C DIR`, booleans,
/// `--` ends the options, and everything else is positional.
nonisolated enum OptionParser {
    enum Kind: Sendable {
        case flag          // no value
        case value         // needs a value
        case optionalValue // -p: a value when the next word is not another option
    }

    struct Spec: Sendable {
        let long: String
        let short: String?
        let kind: Kind
    }

    /// Every option the CLI knows. Commands share one list, so `anvil models --project DIR` also works.
    static let specs: [Spec] = [
        Spec(long: "print", short: "p", kind: .optionalValue),
        Spec(long: "project", short: "C", kind: .value),
        Spec(long: "model", short: nil, kind: .value),
        Spec(long: "mode", short: nil, kind: .value),
        Spec(long: "max-steps", short: nil, kind: .value),
        Spec(long: "max-cost", short: nil, kind: .value),
        Spec(long: "continue", short: nil, kind: .flag),
        Spec(long: "resume", short: nil, kind: .value),
        Spec(long: "no-verify", short: nil, kind: .flag),
        Spec(long: "no-review", short: nil, kind: .flag),
        Spec(long: "no-judge", short: nil, kind: .flag),
        Spec(long: "no-stream", short: nil, kind: .flag),
        Spec(long: "timeout", short: nil, kind: .value),
        Spec(long: "approve", short: nil, kind: .flag),
        Spec(long: "output", short: nil, kind: .value),
        Spec(long: "quiet", short: "q", kind: .flag),
        Spec(long: "all", short: nil, kind: .flag),
        Spec(long: "help", short: "h", kind: .flag),
        Spec(long: "version", short: nil, kind: .flag),
    ]

    /// Parses the words after the program name.
    static func parse(_ args: [String]) throws -> CLIOptions {
        var o = CLIOptions()
        var i = 0
        var onlyPositionals = false
        while i < args.count {
            let word = args[i]
            i += 1
            if onlyPositionals || word == "-" || !word.hasPrefix("-") {
                o.positionals.append(word)
                continue
            }
            if word == "--" { onlyPositionals = true; continue }

            // Resolve the option name and any inline value.
            var name: String
            var inline: String?
            let isLong = word.hasPrefix("--")
            let body = isLong ? String(word.dropFirst(2)) : String(word.dropFirst(1))
            if let eq = body.firstIndex(of: "=") {
                name = String(body[..<eq])
                inline = String(body[body.index(after: eq)...])
            } else {
                name = body
            }
            // A short option may carry its value attached: -C/tmp/x.
            if !isLong, name.count > 1, let first = name.first, let spec = specs.first(where: { $0.short == String(first) }), spec.kind != .flag {
                name = String(first)
                inline = String(body.dropFirst(1))
            }
            let spec: Spec
            if isLong {
                guard let found = specs.first(where: { $0.long == name }) else {
                    throw OptionError(message: unknown(word))
                }
                spec = found
            } else {
                guard let found = specs.first(where: { $0.short == name }) else {
                    throw OptionError(message: unknown(word))
                }
                spec = found
            }

            var value: String?
            switch spec.kind {
            case .flag:
                if inline != nil { throw OptionError(message: "--\(spec.long) takes no value.") }
            case .value:
                if let inline { value = inline }
                else if i < args.count { value = args[i]; i += 1 }
                else { throw OptionError(message: "--\(spec.long) needs a value. Try --\(spec.long) VALUE.") }
            case .optionalValue:
                if let inline { value = inline }
                else if i < args.count, args[i] == "-" || !args[i].hasPrefix("-") { value = args[i]; i += 1 }
            }
            try apply(spec.long, value, to: &o)
        }
        return o
    }

    private static func apply(_ name: String, _ value: String?, to o: inout CLIOptions) throws {
        switch name {
        case "print":
            if let v = value, v != "-" { o.prompt = v } else { o.promptFromStdin = true }
        case "project": o.project = value
        case "model": o.model = value
        case "mode":
            guard let v = value, ["ask", "edits", "plan", "bypass"].contains(v) else {
                throw OptionError(message: "--mode must be one of ask, edits, plan, bypass (got \(value ?? "nothing")).")
            }
            o.mode = v
        case "max-steps":
            guard let n = Int(value ?? ""), n > 0 else { throw OptionError(message: "--max-steps needs a whole number above 0.") }
            o.maxSteps = n
        case "max-cost":
            guard let x = Double(value ?? ""), x >= 0 else { throw OptionError(message: "--max-cost needs a dollar amount such as 0.50.") }
            o.maxCost = x
        case "continue": o.continueLast = true
        case "resume":
            guard let v = value, !v.isEmpty else { throw OptionError(message: "--resume needs a session id (see `anvil sessions`).") }
            o.resume = v
        case "no-verify": o.noVerify = true
        case "no-review": o.noReview = true
        case "no-judge": o.noJudge = true
        case "no-stream": o.noStream = true
        case "timeout":
            guard let x = Double(value ?? ""), x > 0 else { throw OptionError(message: "--timeout needs a number of seconds above 0.") }
            o.timeout = x
        case "approve": o.approve = true
        case "output":
            guard let v = value, let f = OutputFormat(rawValue: v) else {
                throw OptionError(message: "--output must be one of text, json, stream-json (got \(value ?? "nothing")).")
            }
            o.output = f
        case "quiet": o.quiet = true
        case "all": o.all = true
        case "help": o.help = true
        case "version": o.version = true
        default: break
        }
    }

    /// The message for an unknown option, with the closest known name when it is near enough.
    static func unknown(_ word: String) -> String {
        let typed = String(word.drop { $0 == "-" }).lowercased()
        let names = specs.flatMap { spec -> [String] in
            var out = ["--" + spec.long]
            if let s = spec.short { out.append("-" + s) }
            return out
        }
        let best = names.map { ($0, distance(typed, String($0.drop { $0 == "-" }))) }
            .filter { $0.1 <= 2 }
            .min { $0.1 < $1.1 }
        var msg = "unknown option \(word)."
        if let best { msg += " Did you mean \(best.0)?" }
        msg += " Run `anvil --help` for the list."
        return msg
    }

    /// Levenshtein distance between two strings.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[y.count]
    }
}

extension CLIOptions {
    /// Parses the words after the program name.
    static func parse(_ args: [String]) throws -> CLIOptions { try OptionParser.parse(args) }
}
