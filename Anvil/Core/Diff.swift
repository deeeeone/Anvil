import Foundation

/// Line diffs for review: unified text for the model and logs, structured hunks for the UI.
nonisolated enum DiffEngine {
    enum Kind: String, Codable, Sendable { case context, add, remove }

    struct Line: Equatable, Sendable, Codable {
        var kind: Kind
        var text: String
        var oldNo: Int?
        var newNo: Int?
    }

    struct Hunk: Equatable, Sendable {
        var oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        var lines: [Line]
        var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
    }

    static func lines(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var parts = s.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Every line of the comparison in order (Myers diff via CollectionDifference).
    static func script(old: String, new: String) -> [Line] {
        let a = lines(old), b = lines(new)
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [Line] = []
        out.reserveCapacity(max(a.count, b.count))
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count && removed.contains(i) {
                out.append(Line(kind: .remove, text: a[i], oldNo: i + 1, newNo: nil)); i += 1
            } else if j < b.count && inserted.contains(j) {
                out.append(Line(kind: .add, text: b[j], oldNo: nil, newNo: j + 1)); j += 1
            } else if i < a.count && j < b.count {
                out.append(Line(kind: .context, text: a[i], oldNo: i + 1, newNo: j + 1)); i += 1; j += 1
            } else if i < a.count {
                out.append(Line(kind: .remove, text: a[i], oldNo: i + 1, newNo: nil)); i += 1
            } else {
                out.append(Line(kind: .add, text: b[j], oldNo: nil, newNo: j + 1)); j += 1
            }
        }
        return out
    }

    static func hunks(old: String, new: String, context: Int = 3) -> [Hunk] {
        let all = script(old: old, new: new)
        let changed = all.indices.filter { all[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        // Merge change ranges whose context windows touch.
        var ranges: [ClosedRange<Int>] = []
        for idx in changed {
            let lo = max(0, idx - context), hi = min(all.count - 1, idx + context)
            if let last = ranges.last, lo <= last.upperBound + 1 { ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, hi) }
            else { ranges.append(lo...hi) }
        }
        return ranges.map { r in
            let ls = Array(all[r])
            // Start numbers: the first old/new line number in the hunk, or the position just before it for pure inserts/deletes.
            let oldNos = ls.compactMap(\.oldNo), newNos = ls.compactMap(\.newNo)
            let oldBefore = all[..<r.lowerBound].compactMap(\.oldNo).last ?? 0
            let newBefore = all[..<r.lowerBound].compactMap(\.newNo).last ?? 0
            return Hunk(oldStart: oldNos.first ?? oldBefore, oldCount: oldNos.count,
                        newStart: newNos.first ?? newBefore, newCount: newNos.count, lines: ls)
        }
    }

    static func unified(old: String, new: String, path: String, context: Int = 3) -> String {
        let hs = hunks(old: old, new: new, context: context)
        guard !hs.isEmpty else { return "" }
        var out = "--- a/\(path)\n+++ b/\(path)\n"
        for h in hs {
            out += h.header + "\n"
            for l in h.lines {
                out += (l.kind == .add ? "+" : l.kind == .remove ? "-" : " ") + l.text + "\n"
            }
        }
        return out
    }

    static func stats(old: String, new: String) -> (added: Int, removed: Int) {
        let s = script(old: old, new: new)
        return (s.filter { $0.kind == .add }.count, s.filter { $0.kind == .remove }.count)
    }

    /// Parses unified diff text back into display lines (for the UI and for git diff output).
    static func parseUnified(_ text: String) -> [Line] {
        var out: [Line] = []
        var oldNo = 0, newNo = 0
        let header = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                let ns = NSString(string: raw)
                if let m = header.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                    oldNo = Int(ns.substring(with: m.range(at: 1))) ?? 0
                    newNo = Int(ns.substring(with: m.range(at: 2))) ?? 0
                }
                out.append(Line(kind: .context, text: raw, oldNo: nil, newNo: nil))
            } else if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("diff ") || raw.hasPrefix("index ") {
                continue
            } else if raw.hasPrefix("+") {
                out.append(Line(kind: .add, text: String(raw.dropFirst()), oldNo: nil, newNo: newNo)); newNo += 1
            } else if raw.hasPrefix("-") {
                out.append(Line(kind: .remove, text: String(raw.dropFirst()), oldNo: oldNo, newNo: nil)); oldNo += 1
            } else if raw.hasPrefix(" ") {
                out.append(Line(kind: .context, text: String(raw.dropFirst()), oldNo: oldNo, newNo: newNo)); oldNo += 1; newNo += 1
            }
        }
        return out
    }
}

/// A proposed or applied change to one file. `old == nil` means the file is new; `new == nil` deletes it.
nonisolated struct FileChange: Sendable, Equatable {
    var url: URL
    var old: String?
    var new: String?

    func diff(root: URL?) -> FileDiff {
        let path = Paths.display(url, root: root)
        let s = DiffEngine.stats(old: old ?? "", new: new ?? "")
        return FileDiff(path: path, unified: DiffEngine.unified(old: old ?? "", new: new ?? "", path: path),
                        added: s.added, removed: s.removed, isNew: old == nil, isDeleted: new == nil)
    }

    func apply() throws {
        if let new {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try new.write(to: url, atomically: true, encoding: .utf8)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// What the UI keeps of a change: the unified diff and its size.
nonisolated struct FileDiff: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var path: String
    var unified: String
    var added: Int
    var removed: Int
    var isNew = false
    var isDeleted = false

    var statLabel: String { isNew ? "new, +\(added)" : isDeleted ? "deleted" : "+\(added) -\(removed)" }
}
