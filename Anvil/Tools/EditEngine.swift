import Foundation

/// Exact find/replace with a uniqueness check and recovery hints (pure, so it is unit tested).
nonisolated enum EditEngine {
    struct Edit: Sendable { var find: String; var replace: String; var all = false }

    static func apply(_ text: String, _ e: Edit, file: String) throws -> (text: String, count: Int) {
        guard !e.find.isEmpty else { throw ToolFailure("find is empty. To create or overwrite a file use write_file.") }
        if e.find == e.replace { throw ToolFailure("find and replace are identical, nothing to change") }
        var find = e.find, replace = e.replace
        // CRLF files: match with the file's line endings.
        if text.contains("\r\n") && !find.contains("\r\n") {
            find = find.replacingOccurrences(of: "\n", with: "\r\n")
            replace = replace.replacingOccurrences(of: "\n", with: "\r\n")
        }
        var n = occurrences(of: find, in: text)
        if n == 0, let stripped = stripLineNumbers(find) {
            // The model copied read_file's line-number prefixes.
            let r = stripLineNumbers(replace) ?? replace
            if occurrences(of: stripped, in: text) > 0 { find = stripped; replace = r; n = occurrences(of: find, in: text) }
        }
        if n == 0 { throw ToolFailure(notFound(find, in: text, file: file)) }
        if n > 1 && !e.all {
            let lines = lineNumbers(of: find, in: text).prefix(6).map(String.init).joined(separator: ", ")
            throw ToolFailure("find text matches \(n) places in \(file) (lines \(lines)). Include more surrounding lines so it matches exactly one, or pass \"all\": true to replace every match.")
        }
        let out = e.all ? text.replacingOccurrences(of: find, with: replace) : text.replacingCharacters(in: text.range(of: find)!, with: replace)
        return (out, e.all ? n : 1)
    }

    /// Applies several edits in order; all or nothing.
    static func applyAll(_ text: String, _ edits: [Edit], file: String) throws -> String {
        var t = text
        for (i, e) in edits.enumerated() {
            do { t = try apply(t, e, file: file).text }
            catch let f as ToolFailure { throw ToolFailure("edit \(i + 1) of \(edits.count): \(f.message) (no edits were applied)") }
        }
        return t
    }

    static func occurrences(of needle: String, in hay: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = hay.startIndex..<hay.endIndex
        while let r = hay.range(of: needle, range: range) {
            count += 1
            range = r.upperBound..<hay.endIndex
        }
        return count
    }

    static func lineNumbers(of needle: String, in hay: String) -> [Int] {
        var out: [Int] = []
        var range = hay.startIndex..<hay.endIndex
        while let r = hay.range(of: needle, range: range), out.count < 20 {
            out.append(hay[hay.startIndex..<r.lowerBound].filter { $0 == "\n" }.count + 1)
            range = r.upperBound..<hay.endIndex
        }
        return out
    }

    /// "  12\tfoo" lines (read_file output) back to "foo"; nil if not every non-empty line has a prefix.
    static func stripLineNumbers(_ s: String) -> String? {
        let lines = s.components(separatedBy: "\n")
        let re = try! NSRegularExpression(pattern: #"^\s*\d+(\t|→|\|)"#)
        var out: [String] = []
        var any = false
        for l in lines {
            let ns = NSString(string: l)
            if let m = re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                out.append(ns.substring(from: m.range.length)); any = true
            } else if l.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(l)
            } else { return nil }
        }
        return any ? out.joined(separator: "\n") : nil
    }

    static func notFound(_ find: String, in text: String, file: String) -> String {
        let firstLine = find.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? find
        let key = firstLine.trimmingCharacters(in: .whitespaces)
        let lines = text.components(separatedBy: "\n")
        var hint = ""
        if let near = lines.enumerated().first(where: { $0.element.contains(key) || (key.count > 16 && $0.element.contains(String(key.prefix(16)))) }) {
            let lo = max(0, near.offset - 1), hi = min(lines.count - 1, near.offset + 3)
            hint = "\nThe closest match starts near line \(near.offset + 1); the file there reads:\n" + (lo...hi).map { "\($0 + 1)\t\(lines[$0])" }.joined(separator: "\n")
        } else {
            // Whitespace-insensitive check.
            let squash = { (s: String) in s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
            if squash(text).contains(squash(find)) { hint = "\nThe text exists with different whitespace or indentation. Copy it exactly from read_file (without the line numbers)." }
        }
        return "find text not found in \(file). It must match the file exactly, including indentation. read_file the area first.\(hint)"
    }
}
