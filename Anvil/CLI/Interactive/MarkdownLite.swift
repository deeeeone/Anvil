import Foundation

/// A small markdown renderer for the terminal: enough for the agent's final answers, nothing more.
///
/// Handled: `#` headings (bold), `**bold**`, `` `code` `` (cyan), fenced code blocks (indented, with a dim gutter),
/// `-`, `*` and `1.` lists (kept as written), and `[text](url)` links (shown as `text (url)`). Everything else is
/// plain text. Styles come from `Ansi`, so with color off the output is plain text.
/// Why not a real parser: the answers are short and the output must stay predictable in a fixed-width terminal.
nonisolated enum MarkdownLite {
    static func render(_ text: String, width: Int) -> [String] {
        let cols = max(20, width)
        var out: [String] = []
        var inCode = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                // Code is not wrapped: a long line is cut, so the gutter stays aligned.
                out.append("  " + Ansi.gray("│ ") + Ansi.truncate(line, width: max(1, cols - 4)))
                continue
            }
            if trimmed.isEmpty {
                out.append("")
                continue
            }
            if let heading = headingText(trimmed) {
                for row in Ansi.wrap(Ansi.bold(inline(heading)), width: cols) { out.append(row) }
                continue
            }
            // Lists keep their marker; continuation rows indent under the item text.
            let (marker, body, indentWidth) = listParts(line)
            let rows = Ansi.wrap(marker + inline(body), width: cols)
            for (i, row) in rows.enumerated() {
                out.append(i == 0 ? row : String(repeating: " ", count: indentWidth) + row)
            }
        }
        // Drop trailing blank rows so the final answer ends cleanly.
        while out.last == "" { out.removeLast() }
        return out
    }

    /// The text of an ATX heading ("## Title" → "Title"), or nil when the line is not a heading.
    static func headingText(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6, trimmed.dropFirst(hashes.count).first == " " else { return nil }
        return String(trimmed.dropFirst(hashes.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Splits a list line into its marker (printed as is, with the original indent), the body and the width to indent
    /// continuation rows by. Non-list lines return an empty marker.
    static func listParts(_ line: String) -> (marker: String, body: String, indent: Int) {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let rest = String(line.dropFirst(leading.count))
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            let marker = String(leading) + String(bullet.prefix(1)) + " "
            return (marker, String(rest.dropFirst(2)), marker.count)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". ") {
            let head = String(digits) + ". "
            let marker = String(leading) + head
            return (marker, String(rest.dropFirst(head.count)), marker.count)
        }
        return ("", line, 0)
    }

    /// Inline spans: links, `code`, and **bold**. Code is left alone by the other rules.
    static func inline(_ text: String) -> String {
        // Split on code spans first: everything inside backticks is literal and cyan. An unclosed backtick stays literal.
        let parts = text.components(separatedBy: "`")
        if parts.count % 2 == 0 { return styleOutside(text) }
        var out = ""
        for (i, part) in parts.enumerated() {
            out += i % 2 == 1 ? (part.isEmpty ? "" : Ansi.cyan(part)) : styleOutside(part)
        }
        return out
    }

    private static func styleOutside(_ text: String) -> String {
        links(in: text).map { chunk -> String in
            switch chunk {
            case .plain(let s): return bold(s)
            case .link(let label, let url): return bold(label) + " (" + url + ")"
            }
        }.joined()
    }

    /// Bold runs between `**` pairs. An unpaired `**` stays as it is.
    private static func bold(_ text: String) -> String {
        let parts = text.components(separatedBy: "**")
        guard parts.count > 1, parts.count % 2 == 1 else { return text }
        var out = ""
        for (i, part) in parts.enumerated() {
            out += i % 2 == 1 ? Ansi.bold(part) : part
        }
        return out
    }

    private enum Chunk {
        case plain(String)
        case link(label: String, url: String)
    }

    /// Finds `[label](url)` in the text. Anything else is plain.
    private static func links(in text: String) -> [Chunk] {
        guard let re = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#) else { return [.plain(text)] }
        let ns = NSString(string: text)
        var chunks: [Chunk] = []
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last {
                chunks.append(.plain(ns.substring(with: NSRange(location: last, length: m.range.location - last))))
            }
            chunks.append(.link(label: ns.substring(with: m.range(at: 1)), url: ns.substring(with: m.range(at: 2))))
            last = m.range.location + m.range.length
        }
        if last < ns.length { chunks.append(.plain(ns.substring(from: last))) }
        return chunks.isEmpty ? [.plain(text)] : chunks
    }
}
