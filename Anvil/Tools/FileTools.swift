import Foundation
import AppKit

/// Reading, writing, editing and searching files in the project.
enum FileTools {
    static func all() -> [ToolSpec] { [readFile, listDir, glob, grep, editFile, multiEdit, writeFile, deleteFile] }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    static func readText(_ url: URL) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ToolFailure("\(url.path) doesn't exist. Use glob or list_dir to find the right path.") }
        if isDir.boolValue { throw ToolFailure("\(url.lastPathComponent) is a folder; use list_dir") }
        let data = try Data(contentsOf: url)
        if data.count > 8_000_000 { throw ToolFailure("file is \(data.count / 1_000_000) MB, too big to read whole; use grep or shell (head/sed -n) on it") }
        if data.prefix(8000).contains(0) { throw ToolFailure("\(url.lastPathComponent) looks binary") }
        return String(decoding: data, as: UTF8.self)
    }

    static func numbered(_ text: String, offset: Int, limit: Int) -> (String, Int, Int, Int) {
        let lines = DiffEngine.lines(text)
        let start = max(1, offset)
        let end = min(lines.count, start + limit - 1)
        guard start <= lines.count else { return ("", start, end, lines.count) }
        let width = String(end).count
        let body = (start...end).map { i -> String in
            var l = lines[i - 1]
            if l.count > 600 { l = String(l.prefix(600)) + "…[line truncated]" }
            return String(repeating: " ", count: max(0, width - String(i).count)) + "\(i)\t" + l
        }.joined(separator: "\n")
        return (body, start, end, lines.count)
    }

    static let readFile = ToolSpec(
        name: "read_file", kind: .read,
        signature: #"{"path": str, optional "offset": first line (1-based), "limit": lines (default 400)}"#,
        summary: "read a text file with line numbers (number, tab, text). Read big files in ranges. Images are attached so you can see them",
        group: .files
    ) { a, ctx in
        guard let p = a["path"]?.string ?? a["file"]?.string ?? a["value"]?.string else { return .fail("missing path") }
        let url = ctx.resolve(p)
        if imageExts.contains(url.pathExtension.lowercased()), let data = try? Data(contentsOf: url) {
            var r = ToolResult.ok("image \(ctx.rel(url)) (\(data.count / 1024) KB) attached")
            r.image = (data, url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg")
            return r
        }
        let text = try readText(url)
        ctx.readFiles.insert(url.standardizedFileURL.path)
        if text.isEmpty { return .ok("\(ctx.rel(url)) is empty") }
        let limit = max(1, min(2000, a["limit"]?.int ?? 400))
        let (body, s, e, total) = numbered(text, offset: a["offset"]?.int ?? a["start_line"]?.int ?? 1, limit: limit)
        if body.isEmpty { return .fail("offset \(s) is past the end (\(total) lines)") }
        let more = e < total ? "\n(lines \(s)-\(e) of \(total); use offset \(e + 1) to read more)" : (s > 1 ? "\n(lines \(s)-\(e) of \(total))" : "")
        return .ok("\(ctx.rel(url)):\n" + body + more)
    }

    static let listDir = ToolSpec(
        name: "list_dir", kind: .read,
        signature: #"{optional "path": folder (default project root), "depth": 1-4 (default 2)}"#,
        summary: "list a folder as a tree (skips .git, node_modules, build output)",
        group: .files
    ) { a, ctx in
        let url = ctx.resolve(a["path"]?.string ?? a["value"]?.string ?? ".")
        let depth = max(1, min(4, a["depth"]?.int ?? 2))
        var lines: [String] = []
        func walk(_ dir: URL, _ d: Int, _ indent: String) {
            guard lines.count < 400, let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return }
            for u in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let name = u.lastPathComponent
                if name == ".DS_Store" { continue }
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    if ProjectContext.skipDirs.contains(name) { lines.append("\(indent)\(name)/ (skipped)"); continue }
                    lines.append("\(indent)\(name)/")
                    if d < depth { walk(u, d + 1, indent + "  ") }
                } else {
                    let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    lines.append("\(indent)\(name)" + (size > 100_000 ? " (\(size / 1024) KB)" : ""))
                }
                if lines.count >= 400 { lines.append("\(indent)… (listing cut at 400 entries; narrow the path)"); return }
            }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return .fail("\(ctx.rel(url)) is not a folder") }
        walk(url, 1, "")
        return .ok("\(ctx.rel(url))/\n" + (lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")))
    }

    // MARK: Search

    /// Files under root, skipping hidden folders and bulky build/vendor folders.
    nonisolated static func walk(_ root: URL, includeDirs: Bool = false) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return [root] }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            let name = u.lastPathComponent
            let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if dir {
                if ProjectContext.skipDirs.contains(name) || (name.hasPrefix(".") && ![".github", ".anvil", ".claude"].contains(name)) { e.skipDescendants(); continue }
                if includeDirs { out.append(u) }
            } else if name != ".DS_Store" {
                out.append(u)
            }
            if out.count > 100_000 { break }
        }
        return out
    }

    /// "**/*.swift" → regex over a relative path. `*` stays within a folder, `**/` spans folders.
    nonisolated static func globRegex(_ glob: String) -> NSRegularExpression? {
        var re = "^"
        var i = glob.startIndex
        var inBrace = false
        while i < glob.endIndex {
            let c = glob[i]
            if c == "*" {
                let n = glob.index(after: i)
                if n < glob.endIndex && glob[n] == "*" {
                    let after = glob.index(after: n)
                    if after < glob.endIndex && glob[after] == "/" { re += "(?:.*/)?"; i = glob.index(after: after); continue }
                    re += ".*"; i = after; continue
                }
                re += "[^/]*"
            } else if c == "?" { re += "[^/]" }
            else if c == "{" { re += "(?:"; inBrace = true }
            else if c == "}" { re += ")"; inBrace = false }
            else if c == "," && inBrace { re += "|" }
            else { re += NSRegularExpression.escapedPattern(for: String(c)) }
            i = glob.index(after: i)
        }
        return try? NSRegularExpression(pattern: re + "$", options: [.caseInsensitive])
    }

    nonisolated static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static let glob = ToolSpec(
        name: "glob", kind: .read,
        signature: #"{"pattern": "**/*.ts" or "src/**/test_*.py", optional "path": base folder}"#,
        summary: "find files by path pattern, newest first",
        group: .search
    ) { a, ctx in
        guard let pat = a["pattern"]?.string ?? a["value"]?.string else { return .fail("missing pattern") }
        let root = ctx.resolve(a["path"]?.string ?? ".")
        guard let re = globRegex(pat.contains("/") ? pat : "**/" + pat) else { return .fail("bad pattern") }
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let hits = await Task.detached { () -> [(String, Date)] in
            walk(root, includeDirs: true).compactMap { url in
                let rel = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
                guard matches(re, rel) else { return nil }
                return (rel, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
        }.value
        if hits.isEmpty { return .ok("no files match \(pat) under \(ctx.rel(root))") }
        let sorted = hits.sorted { $0.1 > $1.1 }
        let prefix = root.path == ctx.root.path ? "" : ctx.rel(root) + "/"
        return .ok(sorted.prefix(200).map { prefix + $0.0 }.joined(separator: "\n") + (sorted.count > 200 ? "\n(\(sorted.count - 200) more; narrow the pattern)" : ""))
    }

    static let grep = ToolSpec(
        name: "grep", kind: .read,
        signature: #"{"pattern": regex, optional "path": folder or file, "glob": "*.swift", "ignore_case": bool, "context": lines around each match (0-5), "limit": int}"#,
        summary: "search file contents with a regex; returns path:line: text",
        group: .search
    ) { a, ctx in
        guard let pat = a["pattern"]?.string ?? a["query"]?.string ?? a["value"]?.string else { return .fail("missing pattern") }
        var opts: NSRegularExpression.Options = []
        if a["ignore_case"]?.bool == true || a["i"]?.bool == true { opts.insert(.caseInsensitive) }
        let re: NSRegularExpression
        if let r = try? NSRegularExpression(pattern: pat, options: opts) { re = r }
        else { re = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pat), options: opts) }
        let root = ctx.resolve(a["path"]?.string ?? ".")
        let nameRE = (a["glob"]?.string ?? a["include"]?.string).flatMap { globRegex($0.contains("/") ? $0 : "**/" + $0) }
        let limit = max(1, min(400, a["limit"]?.int ?? 120))
        let context = max(0, min(5, a["context"]?.int ?? 0))
        let projectRoot = ctx.root
        let result = await Task.detached { () -> (lines: [String], files: Int, truncated: Bool) in
            var lines: [String] = []
            var files = 0
            var truncated = false
            let deadline = Date().addingTimeInterval(25)
            let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
            for url in walk(root) {
                if Date() > deadline { truncated = true; break }
                let rel = url.path.hasPrefix(base) ? String(url.path.dropFirst(base.count)) : url.lastPathComponent
                if let nameRE, !matches(nameRE, rel) { continue }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 3_000_000,
                      !data.prefix(4000).contains(0) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                files += 1
                let all = text.components(separatedBy: "\n")
                let shownPath = Paths.display(url, root: projectRoot)
                var lastPrinted = -1
                for (i, line) in all.enumerated() where re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    let lo = max(0, i - context), hi = min(all.count - 1, i + context)
                    if context > 0 && lastPrinted >= 0 && lo > lastPrinted + 1 { lines.append("--") }
                    for k in max(lo, lastPrinted + 1)...hi {
                        let l = all[k].count > 240 ? String(all[k].prefix(240)) + "…" : all[k]
                        lines.append("\(shownPath):\(k + 1)\(k == i ? ":" : "-") \(l)")
                    }
                    lastPrinted = hi
                    if lines.count >= limit { truncated = true; break }
                }
                if lines.count >= limit { break }
            }
            return (lines, files, truncated)
        }.value
        if result.lines.isEmpty { return .ok("no matches for /\(pat)/ in \(result.files) files under \(ctx.rel(root))") }
        return .ok(result.lines.joined(separator: "\n") + (result.truncated ? "\n(stopped at \(result.lines.count) lines; narrow path or glob)" : ""))
    }

    // MARK: Edits (prepared first, so the app can show the diff and ask)

    static func currentText(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readText(url)
    }

    static let editFile = ToolSpec(
        edit: "edit_file",
        signature: #"{"path": str, "find": exact existing text, "replace": new text, optional "all": bool}"#,
        summary: "replace an exact snippet (must match exactly once unless all:true). Copy find from read_file output without the line numbers"
    ) { a, ctx in
        guard let p = a["path"]?.string ?? a["file"]?.string else { throw ToolFailure("missing path") }
        guard let find = a["find"]?.string ?? a["old"]?.string ?? a["old_string"]?.string ?? a["old_str"]?.string ?? a["search"]?.string,
              let repl = a["replace"]?.string ?? a["new"]?.string ?? a["new_string"]?.string ?? a["new_str"]?.string ?? a["replacement"]?.string
        else { throw ToolFailure("need path, find and replace") }
        let url = ctx.resolve(p)
        guard let text = try currentText(url) else { throw ToolFailure("\(ctx.rel(url)) doesn't exist. Use write_file to create it.") }
        let out = try EditEngine.apply(text, .init(find: find, replace: repl, all: a["all"]?.bool ?? a["replace_all"]?.bool ?? false), file: ctx.rel(url))
        return [FileChange(url: url, old: text, new: out.text)]
    }

    static let multiEdit = ToolSpec(
        edit: "multi_edit",
        signature: #"{"edits": [{"path": str, "find": str, "replace": str, optional "all": bool}, ...]} (a top-level "path" applies to edits without one)"#,
        summary: "several exact replacements across one or more files in one step, all or nothing"
    ) { a, ctx in
        guard let list = a["edits"]?.array, !list.isEmpty else { throw ToolFailure("need a non-empty edits list") }
        let defaultPath = a["path"]?.string
        var order: [URL] = []
        var byFile: [URL: [EditEngine.Edit]] = [:]
        for (i, e) in list.enumerated() {
            guard let p = e["path"]?.string ?? e["file"]?.string ?? defaultPath else { throw ToolFailure("edit \(i + 1) has no path") }
            guard let f = e["find"]?.string ?? e["old"]?.string ?? e["old_string"]?.string, let r = e["replace"]?.string ?? e["new"]?.string ?? e["new_string"]?.string
            else { throw ToolFailure("edit \(i + 1) needs find and replace") }
            let url = ctx.resolve(p)
            if byFile[url] == nil { order.append(url) }
            byFile[url, default: []].append(.init(find: f, replace: r, all: e["all"]?.bool ?? false))
        }
        return try order.map { url in
            guard let text = try currentText(url) else { throw ToolFailure("\(ctx.rel(url)) doesn't exist (no edits were applied)") }
            return FileChange(url: url, old: text, new: try EditEngine.applyAll(text, byFile[url]!, file: ctx.rel(url)))
        }
    }

    static let writeFile = ToolSpec(
        edit: "write_file",
        signature: #"{"path": str, "content": full file text}"#,
        summary: "create a file or replace its whole content (creates folders). Prefer edit_file for changes to existing files"
    ) { a, ctx in
        guard let p = a["path"]?.string ?? a["file"]?.string, let content = a["content"]?.string ?? a["text"]?.string ?? a["contents"]?.string
        else { throw ToolFailure("need path and content") }
        let url = ctx.resolve(p)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { throw ToolFailure("\(ctx.rel(url)) is a folder") }
        let old = try currentText(url)
        if old == content { throw ToolFailure("\(ctx.rel(url)) already has exactly this content") }
        // Never overwrite a file blind: its real content may differ from what the model assumes.
        if let old, !old.isEmpty, !ctx.readFiles.contains(url.standardizedFileURL.path) {
            throw ToolFailure("\(ctx.rel(url)) already exists and you haven't read it in this session. read_file it first, then use edit_file for changes (or write_file to replace it on purpose).")
        }
        return [FileChange(url: url, old: old, new: content)]
    }

    static let deleteFile = ToolSpec(
        edit: "delete_file",
        signature: #"{"path": str}"#,
        summary: "delete a file (undoable with the task checkpoint)"
    ) { a, ctx in
        guard let p = a["path"]?.string ?? a["value"]?.string else { throw ToolFailure("missing path") }
        let url = ctx.resolve(p)
        guard let old = try currentText(url) else { throw ToolFailure("\(ctx.rel(url)) doesn't exist") }
        return [FileChange(url: url, old: old, new: nil)]
    }
}
