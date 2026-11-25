import Foundation

/// Removes secrets (API keys, tokens, cookies, passwords) from text before it is saved anywhere outside the Mac.
nonisolated enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            (#"sk-ant-[A-Za-z0-9_\-]{10,}"#, "[redacted]"),
            (#"(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{16,}"#, "[redacted]"),
            (#"AIza[0-9A-Za-z_\-]{30,}"#, "[redacted]"),
            (#"gh[pousr]_[A-Za-z0-9]{20,}"#, "[redacted]"),
            (#"github_pat_[A-Za-z0-9_]{20,}"#, "[redacted]"),
            (#"xox[a-z]-[A-Za-z0-9\-]{10,}"#, "[redacted]"),
            (#"AKIA[0-9A-Z]{16}"#, "[redacted]"),
            (#"eyJ[A-Za-z0-9_\-]{5,}\.eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#, "[redacted]"),
            (#"(?i)(Bearer\s+)[A-Za-z0-9._~+/=\-]{8,}"#, "$1[redacted]"),
            (#"(?i)((?:Set-)?Cookie:[ \t]*)[^\r\n]+"#, "$1[redacted]"),
            (#"(?i)(Authorization:[ \t]*)[^\r\n]+"#, "$1[redacted]"),
            (#"(?i)"([A-Za-z0-9_\-]*(?:key|token|secret|password|passwd|cookie|session|auth)[A-Za-z0-9_\-]*)"(\s*:\s*)"[^"]*""#, "\"$1\"$2\"[redacted]\""),
            (#"(?i)\b([A-Za-z0-9_\-]*(?:key|token|secret|password|passwd|cookie|session|auth)[A-Za-z0-9_\-]*)=(?!\[redacted\])(?!(?:\d[\d_]*|true|false|nil)(?:[\s;,&]|$))([^\s"'&;,]+)"#, "$1=[redacted]"),
        ]
        return specs.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    /// The text with every recognised secret replaced by `[redacted]`. Ordinary text is returned unchanged.
    static func redact(_ text: String) -> String {
        var out = text
        for (regex, template) in rules {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}
