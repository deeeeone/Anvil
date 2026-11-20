import SwiftUI

/// Light markdown: fenced code blocks as monospaced boxes, inline markdown elsewhere.
struct MarkdownText: View {
    let text: String

    struct Block: Identifiable { let id: Int; let code: Bool; let lang: String; let body: String }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var buf: [String] = []
        var inCode = false
        var lang = ""
        func flush(code: Bool) {
            let body = buf.joined(separator: "\n")
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code { out.append(Block(id: out.count, code: code, lang: lang, body: code ? body : body.trimmingCharacters(in: .newlines))) }
            buf = []
        }
        for line in s.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { flush(code: true); inCode = false; lang = "" }
                else { flush(code: false); inCode = true; lang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)) }
            } else { buf.append(line) }
        }
        flush(code: inCode)
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.blocks(text)) { b in
                if b.code {
                    ScrollView(.horizontal) {
                        Text(b.body).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text).padding(14).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(12, fill: Theme.code)
                } else {
                    Text(Self.inline(b.body)).font(.system(size: 14.5)).foregroundStyle(Theme.text).lineSpacing(3.5)
                }
            }
        }
    }

    static func inline(_ s: String) -> AttributedString {
        // Headings and bullets aren't handled by inline parsing; soften them.
        let cleaned = s.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasPrefix("#") { l.removeFirst() }
            if l != line { l = "**" + l.trimmingCharacters(in: .whitespaces) + "**" }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "•  " + l.dropFirst(2) }
            return l
        }.joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(cleaned)
    }
}
