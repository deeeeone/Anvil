import Foundation

/// Frame source for a busy indicator and an elapsed-time formatter.
/// Why: braille frames look best, but a conhost or a C locale shows them as question marks, so ASCII is the fallback.
nonisolated enum Spinner {
    static let brailleFrames = ["\u{280B}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283C}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280F}"]
    static let asciiFrames = ["|", "/", "-", "\\"]

    /// True when the locale says UTF-8. On Windows, Windows Terminal and other VT hosts set WT_SESSION or TERM_PROGRAM.
    static let unicodeAvailable: Bool = {
        #if os(Windows)
        return TUIEnv.value("WT_SESSION") != nil || TUIEnv.value("TERM_PROGRAM") != nil
        #else
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].compactMap { TUIEnv.value($0) }.first ?? ""
        let lower = locale.lowercased()
        return lower.contains("utf-8") || lower.contains("utf8")
        #endif
    }()

    static var frames: [String] { unicodeAvailable ? brailleFrames : asciiFrames }

    static func frame(at tick: Int) -> String {
        let f = frames
        return f[((tick % f.count) + f.count) % f.count]
    }

    /// "12s" below a minute, "1m 05s" from then on.
    static func elapsed(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let rest = total % 60
        return "\(minutes)m \(rest < 10 ? "0" : "")\(rest)s"
    }
}

/// Reads environment variables. Empty values count as unset.
nonisolated enum TUIEnv {
    static func value(_ name: String) -> String? {
        guard let p = getenv(name) else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }
}
