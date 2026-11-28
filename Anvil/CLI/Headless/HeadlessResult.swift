import Foundation

/// Why a provider-side error happened, from the message the agent reports for it.
nonisolated enum FailureKind: Equatable, Sendable {
    /// Setup is missing (no key, not signed in, no proxy): exit 2.
    case config
    /// The provider failed (rejected key, rate limit, timeout, network, bad reply): exit 3.
    case provider
}

/// Pure rules for a headless run: the stop reason, the exit code and the JSON result. Nothing here touches the agent,
/// so the unit tests can drive every branch.
///
/// The agent reports a failed model call only as text (`AgentHost.agentError`), so the failure kind is read from the
/// message. The prefixes are the ones `BrainError.errorDescription` and the Brain produce.
enum HeadlessExit {
    static let configPrefixes = [
        "No API key yet", "Set up ", "Sign in to ", "Add a ", "Add one", "Set the Luna", "No ChatGPT account", "No Gemini account",
    ]
    static let providerPrefixes = [
        "The provider rejected", "The provider is rate limiting", "The model took too long", "Couldn't reach the provider",
        "The model went silent", "The model was still thinking", "Provider error ", "The model sent an empty reply",
        "The model sent nothing", "The reply stream", "The reply ended", "ChatGPT's web app rejects", "Gemini's web app",
        "The model went quiet",
    ]

    /// The failure kind of an error message, or nil when it is not a provider or setup failure.
    static func classify(_ message: String) -> FailureKind? {
        let m = message.trimmingCharacters(in: .whitespaces)
        if configPrefixes.contains(where: { m.hasPrefix($0) }) { return .config }
        if providerPrefixes.contains(where: { m.hasPrefix($0) }) { return .provider }
        if m.contains(" is signed out of ") { return .provider }
        return nil
    }

    /// The stop reason written to the JSON result and used for the exit code.
    static func reason(ok: Bool, interrupted: Bool, timedOut: Bool, failure: FailureKind?, steps: Int, maxSteps: Int,
                       costLimit: Double, spent: Double, missing: [String]) -> String {
        if interrupted { return "cancelled" }
        if timedOut { return "timeout" }
        if ok { return "done" }
        switch failure {
        case .config?: return "no_provider"
        case .provider?: return "provider"
        case nil: break
        }
        if steps >= maxSteps { return "max_steps" }
        if costLimit > 0 && spent >= costLimit { return "cost_limit" }
        if !missing.isEmpty { return "judge_rejected" }
        return "stopped"
    }

    /// The process exit code for a stop reason (see Help for the table).
    static func code(reason: String) -> Int32 {
        switch reason {
        case "done": return ExitCode.done
        case "no_provider": return ExitCode.usage
        case "provider": return ExitCode.provider
        case "cancelled": return 130
        default: return ExitCode.notDone
        }
    }
}

/// The result of one headless run, as printed by --output json and as the last stream-json line.
nonisolated struct HeadlessSummary: Sendable {
    var ok: Bool
    var answer: String
    var exitReason: String
    var steps: Int
    var seconds: Double
    var cost: Double
    var calls: Int
    var prompt: Int
    var completion: Int
    var cached: Int
    var model: String
    var changed: [String]
    var session: String
    var verified: String

    /// The keys are fixed (the README of the CLI lists them); values are plain JSON types.
    var object: [String: Any] {
        [
            "ok": ok,
            "answer": answer,
            "exitReason": exitReason,
            "steps": steps,
            "seconds": JSONLine.finite(seconds),
            "cost": JSONLine.finite(cost),
            "calls": calls,
            "tokens": ["prompt": prompt, "completion": completion, "cached": cached] as [String: Any],
            "model": model,
            "changed": changed,
            "session": session,
            "verified": verified,
        ]
    }
}

/// One JSON object per line, keys sorted, strings escaped by JSONSerialization.
nonisolated enum JSONLine {
    static func finite(_ x: Double) -> Double { x.isFinite ? x : 0 }

    static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"exitReason\":\"encode_error\"}"
        }
        return s
    }
}
