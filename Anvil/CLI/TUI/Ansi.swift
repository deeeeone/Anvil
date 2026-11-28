import Foundation

/// ANSI styling and terminal display-width helpers for the TUI.
/// Why: the renderer must know how many terminal columns a string occupies to wrap it. Escape codes take no columns,
/// and CJK and emoji take two, so widths come from Unicode properties rather than Character or byte counts. Styles
/// are emitted only when color is on, so piped output and NO_COLOR users get plain text.
nonisolated enum Ansi {
    /// Computed once. Off when NO_COLOR is set (non-empty), TERM=dumb, or stdout is not a terminal.
    static let colorEnabled: Bool = {
        if TUIEnv.value("NO_COLOR") != nil { return false }
        if TUIEnv.value("TERM") == "dumb" { return false }
        return TUITerminal.outputIsTTY
    }()

    /// A complete SGR reset, used to close styles at the end of a wrapped line.
    static let resetSequence = "\u{1B}[0m"

    static func style(_ code: String, _ text: String) -> String {
        colorEnabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { style("1", text) }
    static func dim(_ text: String) -> String { style("2", text) }
    static func italic(_ text: String) -> String { style("3", text) }
    static func red(_ text: String) -> String { style("31", text) }
    static func green(_ text: String) -> String { style("32", text) }
    static func yellow(_ text: String) -> String { style("33", text) }
    static func blue(_ text: String) -> String { style("34", text) }
    static func magenta(_ text: String) -> String { style("35", text) }
    static func cyan(_ text: String) -> String { style("36", text) }
    static func gray(_ text: String) -> String { style("90", text) }
    /// Empty when color is off, so callers can append it unconditionally.
    static var reset: String { colorEnabled ? resetSequence : "" }

    /// A piece of a string: an escape sequence (zero width) or visible text.
    nonisolated enum Piece: Equatable {
        case escape(String)
        case text(String)
    }

    /// Splits a string into escape sequences and visible text. CSI (ESC [ ... final), OSC (ESC ] ... BEL) and
    /// two-byte escapes are recognised; a lone trailing ESC becomes an escape piece.
    static func pieces(_ s: String) -> [Piece] {
        let scalars = Array(s.unicodeScalars)
        let n = scalars.count
        var out: [Piece] = []
        var text = String.UnicodeScalarView()
        var i = 0
        while i < n {
            let u = scalars[i]
            guard u == "\u{1B}" else {
                text.append(u)
                i += 1
                continue
            }
            if !text.isEmpty {
                out.append(.text(String(text)))
                text = String.UnicodeScalarView()
            }
            var j = i + 1
            if j < n && scalars[j] == "[" {
                j += 1
                while j < n && !(scalars[j].value >= 0x40 && scalars[j].value <= 0x7E) { j += 1 }
                j = min(j + 1, n)
            } else if j < n && scalars[j] == "]" {
                while j < n && scalars[j] != "\u{7}" { j += 1 }
                j = min(j + 1, n)
            } else {
                j = min(j + 1, n)
            }
            var seq = String.UnicodeScalarView()
            seq.append(contentsOf: scalars[i..<j])
            out.append(.escape(String(seq)))
            i = j
        }
        if !text.isEmpty { out.append(.text(String(text))) }
        return out
    }

    /// The text with every escape sequence removed.
    static func stripped(_ s: String) -> String {
        var out = ""
        for piece in pieces(s) {
            if case .text(let t) = piece { out += t }
        }
        return out
    }

    /// Terminal columns used by a string, ignoring escape sequences.
    static func displayWidth(_ s: String) -> Int {
        var total = 0
        for piece in pieces(s) {
            if case .text(let t) = piece {
                for ch in t { total += cellWidth(of: ch) }
            }
        }
        return total
    }

    /// Columns used by one grapheme cluster: 2 for wide or emoji-presentation content, 0 for zero-width content
    /// (combining marks, format characters), 1 otherwise. Clusters are measured whole, so "e" plus a combining accent
    /// is one column and a ZWJ emoji sequence is two.
    static func cellWidth(of ch: Character) -> Int {
        var allZeroWidth = true
        var wide = false
        for scalar in ch.unicodeScalars {
            if isWide(scalar) { wide = true }
            if !isZeroWidth(scalar) { allZeroWidth = false }
        }
        if wide || ch.unicodeScalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        return allZeroWidth ? 0 : 1
    }

    private static let wideRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
        0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD,
    ]

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        if wideRanges.contains(where: { $0.contains(scalar.value) }) { return true }
        return scalar.properties.isEmojiPresentation
    }

    private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control: return true
        default: return false
        }
    }

    /// Hard-wraps text to `width` columns, splitting on newlines. Styles stay open across the wrap: each continuation
    /// line starts with the SGR sequences that were active, and a line that ends mid-style is closed with a reset.
    static func wrap(_ text: String, width: Int) -> [String] {
        let limit = max(1, width)
        var rows: [String] = []
        var line = ""
        var lineWidth = 0
        var active: [String] = []

        func breakLine() {
            if !active.isEmpty { line += resetSequence }
            rows.append(line)
            line = active.joined()
            lineWidth = 0
        }

        for piece in pieces(text) {
            switch piece {
            case .escape(let seq):
                line += seq
                if seq.hasPrefix("\u{1B}[") && seq.hasSuffix("m") {
                    if seq == resetSequence || seq == "\u{1B}[m" {
                        active.removeAll()
                    } else {
                        active.append(seq)
                    }
                }
            case .text(let chunk):
                for ch in chunk {
                    if ch == "\n" || ch == "\r\n" {
                        breakLine()
                        continue
                    }
                    if ch == "\r" { continue }
                    let w = cellWidth(of: ch)
                    if lineWidth + w > limit && lineWidth > 0 { breakLine() }
                    line.append(ch)
                    lineWidth += w
                }
            }
        }
        if !active.isEmpty { line += resetSequence }
        rows.append(line)
        return rows
    }

    /// Shortens a string to `width` columns, ending with an ellipsis when it had to be cut. Escape sequences are kept
    /// and the result is closed with a reset if any were kept.
    static func truncate(_ s: String, width: Int) -> String {
        let limit = max(0, width)
        if displayWidth(s) <= limit { return s }
        if limit == 0 { return "" }
        let budget = limit - 1
        var out = ""
        var used = 0
        outer: for piece in pieces(s) {
            switch piece {
            case .escape(let seq):
                out += seq
            case .text(let t):
                for ch in t {
                    let w = cellWidth(of: ch)
                    if used + w > budget { break outer }
                    out.append(ch)
                    used += w
                }
            }
        }
        out += "\u{2026}"
        if out.unicodeScalars.contains("\u{1B}") { out += resetSequence }
        return out
    }
}
