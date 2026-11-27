import Foundation

/// Reads command output for failures that the exit code can hide (a build that prints errors and exits 0, a runner
/// whose failure a `||` swallowed).
nonisolated enum OutputCheck {
    /// Failure markers, tested one output line at a time. Counts only non-zero numbers ("0 failed" is fine).
    static let markers: [String] = [
        #"Failed to compile"#,
        #"error TS\d+"#,
        #"^\s*[✖✗] "#,
        #"^\s*# fail [1-9]"#,
        #"\b[1-9]\d* failed\b"#,
        #"^\s*FAIL "#,
        #"npm ERR!"#,
        #"ERR_PNPM"#,
        #"SyntaxError:"#,
        #"Traceback \(most recent call last\)"#,
        #"BUILD FAILED"#,
        #"^error: "#,
        #"FAILED \(failures="#,
        #"Command failed"#,
    ]

    /// The first output line that shows a failure, or nil when none does.
    static func outputShowsFailure(_ output: String) -> String? {
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard markers.contains(where: { line.range(of: $0, options: .regularExpression) != nil }) else { continue }
            return Fmt.line(line.trimmingCharacters(in: .whitespaces), 200)
        }
        return nil
    }

    /// Whether a shell command has `||` outside quotes (its first failure can be hidden by the second part).
    static func hasOrChain(_ cmd: String) -> Bool {
        var quote: Character?
        var prev: Character?
        for ch in cmd {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "|" && prev == "|" {
                return true
            }
            prev = ch
        }
        return false
    }
}
