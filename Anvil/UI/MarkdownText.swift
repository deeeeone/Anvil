import SwiftUI

/// Sends a message as if the owner typed it (suggestion chips use it).
private struct SendKey: EnvironmentKey { static let defaultValue: ((String) -> Void)? = nil }
extension EnvironmentValues {
    var anvilSend: ((String) -> Void)? {
        get { self[SendKey.self] }
        set { self[SendKey.self] = newValue }
    }
}

/// Markdown for agent replies: headings, paragraphs, lists, tables, quotes, rules and code blocks, with inline
/// bold, italics, code and links. Custom UI tags some models emit (Gemini's <Image/> and <ElicitationsGroup>) are
/// dropped or turned into suggestion chips.
struct MarkdownText: View {
    let text: String

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullets([String])
        case numbered([(Int, String)])
        case quote(String)
        case code(String, String)
        case table([String], [[String]])
        case rule
        case suggestions(String, [(label: String, query: String)])

        static func == (a: Block, b: Block) -> Bool { "\(a)" == "\(b)" }
    }

    static func parse(_ s: String) -> [Block] {
        let lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Block] = []
        var i = 0
        var para: [String] = []
        func flush() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(t)) }
            para = []
        }
        func attr(_ name: String, in line: String) -> String? {
            guard let r = line.range(of: #"\#(name)="([^"]*)""#, options: .regularExpression) else { return nil }
            let m = String(line[r])
            return String(m.dropFirst(name.count + 2).dropLast())
        }
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            // Fenced code.
            if t.hasPrefix("```") {
                flush()
                let lang = String(t.dropFirst(3))
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(lines[i]); i += 1 }
                out.append(.code(lang, body.joined(separator: "\n")))
                i += 1
                continue
            }
            // Gemini's suggestion group: <ElicitationsGroup message="..."> <Elicitation label=".." query=".."/> ... </ElicitationsGroup>
            if t.hasPrefix("<ElicitationsGroup") {
                flush()
                let message = attr("message", in: t) ?? ""
                var items: [(String, String)] = []
                var j = i
                var chunk = ""
                while j < lines.count {
                    chunk += lines[j] + " "
                    if lines[j].contains("</ElicitationsGroup>") { break }
                    j += 1
                }
                let re = try! NSRegularExpression(pattern: #"<Elicitation\s+[^>]*?label="([^"]*)"[^>]*?query="([^"]*)""#)
                let ns = chunk as NSString
                for m in re.matches(in: chunk, range: NSRange(location: 0, length: ns.length)) {
                    items.append((ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))))
                }
                if !items.isEmpty { out.append(.suggestions(message, items)) }
                i = j + 1
                continue
            }
            // Other component-style tags on their own line (<Image .../>, <Card>...): not markdown, drop them.
            if t.range(of: #"^</?[A-Z][A-Za-z]*(\s[^>]*)?/?>\s*$"#, options: .regularExpression) != nil
                || (t.hasPrefix("<Image") && t.hasSuffix("/>")) {
                flush(); i += 1; continue
            }
            if t.hasPrefix("<Image") {   // a multi-line <Image ... /> tag
                flush()
                while i < lines.count, !lines[i].contains("/>") { i += 1 }
                i += 1
                continue
            }
            // Horizontal rule.
            if t.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil { flush(); out.append(.rule); i += 1; continue }
            // Heading.
            if let r = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = t[r].filter { $0 == "#" }.count
                out.append(.heading(level, String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
                i += 1
                continue
            }
            // Table: a header row, a separator row, then rows.
            if t.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#, options: .regularExpression) != nil {
                flush()
                func cells(_ l: String) -> [String] {
                    var s = l.trimmingCharacters(in: .whitespaces)
                    if s.hasPrefix("|") { s.removeFirst() }
                    if s.hasSuffix("|") { s.removeLast() }
                    return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let header = cells(t)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var r = cells(lines[i])
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                out.append(.table(header, rows))
                continue
            }
            // Bullet list (continuation lines are indented).
            if t.range(of: #"^[-*+•]\s+"#, options: .regularExpression) != nil {
                flush()
                var items: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let r = l.range(of: #"^[-*+•]\s+"#, options: .regularExpression) { items.append(String(l[r.upperBound...])) }
                    else if !l.isEmpty, lines[i].hasPrefix("  "), !items.isEmpty { items[items.count - 1] += " " + l }
                    else { break }
                    i += 1
                }
                out.append(.bullets(items))
                continue
            }
            // Numbered list.
            if t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil {
                flush()
                var items: [(Int, String)] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let r = l.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                        items.append((Int(l[r].filter(\.isNumber)) ?? items.count + 1, String(l[r.upperBound...])))
                    } else if !l.isEmpty, lines[i].hasPrefix("  "), !items.isEmpty { items[items.count - 1].1 += " " + l }
                    else { break }
                    i += 1
                }
                out.append(.numbered(items))
                continue
            }
            // Quote.
            if t.hasPrefix(">") {
                flush()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(q.joined(separator: "\n")))
                continue
            }
            if t.isEmpty { flush() } else { para.append(line) }
            i += 1
        }
        flush()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, b in
                BlockView(block: b)
            }
        }
    }
}

private struct BlockView: View {
    @Environment(\.anvilSend) private var send
    let block: MarkdownText.Block

    var body: some View {
        switch block {
        case .heading(let level, let t):
            Text(MarkdownText.inline(t))
                .font(.system(size: level == 1 ? 20 : level == 2 ? 17 : 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let t):
            Text(MarkdownText.inline(t)).font(.system(size: 14.5)).foregroundStyle(Theme.text).lineSpacing(3.5)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(Theme.text3).frame(width: 4.5, height: 4.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(MarkdownText.inline(it)).font(.system(size: 14.5)).foregroundStyle(Theme.text).lineSpacing(3)
                    }
                }
            }
            .padding(.leading, 4)
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(it.0).").font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(Theme.text3).frame(minWidth: 18, alignment: .trailing)
                        Text(MarkdownText.inline(it.1)).font(.system(size: 14.5)).foregroundStyle(Theme.text).lineSpacing(3)
                    }
                }
            }
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent.opacity(0.6)).frame(width: 3)
                Text(MarkdownText.inline(t)).font(.system(size: 14)).foregroundStyle(Theme.text2).italic()
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(_, let body):
            ScrollView(.horizontal) {
                Text(body).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text).padding(14).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(12, fill: Theme.code)
        case .rule:
            Hairline().padding(.vertical, 4)
        case .table(let header, let rows):
            // Fits the column width; long cells wrap instead of scrolling sideways.
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, h in
                        Text(MarkdownText.inline(h)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .background(Theme.surface2)
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            // Every cell fills the row's height, so stripes and dividers stay continuous when one cell wraps.
                            Text(MarkdownText.inline(cell)).font(.system(size: 13)).foregroundStyle(Theme.text2).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(r % 2 == 1 ? Theme.surface.opacity(0.55) : Theme.window)
                                .overlay(alignment: .top) { Hairline() }
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border))
            .textSelection(.enabled)
        case .suggestions(let message, let items):
            VStack(alignment: .leading, spacing: 8) {
                if !message.isEmpty { Text(message).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text2) }
                FlowLayout(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        Button { send?(it.query) } label: {
                            Label(it.label, systemImage: "arrow.turn.down.right").font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(Pill(kind: .ghost))
                        .help(it.query)
                        .disabled(send == nil)
                    }
                }
            }
        }
    }
}

/// Wraps its children onto new lines when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
