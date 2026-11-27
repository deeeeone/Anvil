import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Reading, writing, editing and searching files in the project.
enum FileTools {
    static func all() -> [ToolSpec] { [readFile, listDir, glob, grep, editFile, replaceLines, multiEdit, writeFile, deleteFile] }

    /// Files under `root` from the project's index when possible (instant on big repos), else a fresh walk.
    static func files(under root: URL, ctx: ToolContext) async -> [URL] {
        guard Paths.isInside(root, root: ctx.root) else { return await Task.detached { walk(root) }.value }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [root] }
        let all = await FileIndex.of(ctx.root).list()
        if root.standardizedFileURL.path == ctx.root.standardizedFileURL.path { return all }
        let prefix = root.standardizedFileURL.path + "/"
        return all.filter { $0.standardizedFileURL.path.hasPrefix(prefix) }
    }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    /// `forEdit`: refuse files that aren't valid UTF-8. Decoding them replaces bad bytes with U+FFFD, and writing that
    /// back would silently destroy the original text (Latin-1 accents, Shift-JIS, binary-ish data).
    static func readText(_ url: URL, forEdit: Bool = false) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ToolFailure("\(url.path) doesn't exist. Use glob or list_dir to find the right path.") }
        if isDir.boolValue { throw ToolFailure("\(url.lastPathComponent) is a folder; use list_dir") }
        let data = try Data(contentsOf: url)
        if data.count > 8_000_000 { throw ToolFailure("file is \(data.count / 1_000_000) MB, too big to edit or load whole; read it in ranges with read_file offset/limit, search with grep, and change it with a shell command (sed -i, python) instead") }
        if data.prefix(8000).contains(0) { throw ToolFailure("\(url.lastPathComponent) looks binary") }
        if forEdit, String(data: data, encoding: .utf8) == nil {
            throw ToolFailure("\(url.lastPathComponent) isn't valid UTF-8 (probably Latin-1 or another legacy encoding), so editing it here would corrupt the non-ASCII characters. Change it with a shell command that keeps the bytes, e.g. sed -i '' 's/old/new/' \(url.lastPathComponent) (ASCII only) or python3 with encoding='latin-1'.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Lines `offset...offset+limit-1` of a file too big to load, streamed in 4 MB chunks.
    static func readLargeRange(_ url: URL, rel: String, size: Int, offset: Int, limit: Int) throws -> ToolResult {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .fail("can't open \(rel)") }
        defer { try? h.close() }
        if let head = try h.read(upToCount: 8000), head.contains(0) { return .fail("\(url.lastPathComponent) looks binary") }
        try h.seek(toOffset: 0)
        let start = max(1, offset)
        var lineNo = 1                 // number of the line currently being scanned
        var current = Data()           // bytes of the current line (only kept inside the wanted range)
        var out: [String] = []
        var pastLimit = false
        func finishLine() {
            if lineNo >= start && lineNo < start + limit {
                var l = String(decoding: current, as: UTF8.self)
                if l.hasSuffix("\r") { l.removeLast() }
                if l.count > 600 { l = String(l.prefix(600)) + "…[line truncated]" }
                out.append("\(lineNo)\t" + l)
            }
            current.removeAll(keepingCapacity: true)
            lineNo += 1
            if lineNo >= start + limit { pastLimit = true }
        }
        scan: while let chunk = try h.read(upToCount: 4_000_000), !chunk.isEmpty {
            var from = chunk.startIndex
            while from < chunk.endIndex {
                let wanted = lineNo >= start && lineNo < start + limit
                if let nl = chunk[from...].firstIndex(of: 0x0A) {
                    if wanted { current.append(chunk[from..<nl]) }
                    finishLine()
                    from = chunk.index(after: nl)
                    if pastLimit { break scan }
                } else {
                    if wanted { current.append(chunk[from...]) }
                    break
                }
            }
        }
        if !pastLimit && !current.isEmpty { finishLine() }
        if out.isEmpty { return .fail("offset \(start) is past the end of \(rel) (\(size / 1_000_000) MB)") }
        let last = start + out.count - 1
        return .ok("\(rel) (\(size / 1_000_000) MB, too big to load whole; showing lines \(start)-\(last)):\n" + out.joined(separator: "\n")
                   + (pastLimit ? "\n(use offset \(last + 1) to read more, or grep / shell for searching)" : ""))
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
        // Files too big to load whole (logs, datasets) can still be read in ranges, streamed from disk.
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 8_000_000 {
            let limit = max(1, min(2000, a["limit"]?.int ?? 400))
            return try readLargeRange(url, rel: ctx.rel(url), size: size, offset: a["offset"]?.int ?? a["start_line"]?.int ?? 1, limit: limit)
        }
        let text = try readText(url)
        let lossy = (try? readText(url, forEdit: true)) == nil
        ctx.readFiles.insert(url.standardizedFileURL.path)
        ctx.stamp(url)
        if text.isEmpty { return .ok("\(ctx.rel(url)) is empty") }
        let limit = max(1, min(2000, a["limit"]?.int ?? 400))
        let (body, s, e, total) = numbered(text, offset: a["offset"]?.int ?? a["start_line"]?.int ?? 1, limit: limit)
        if body.isEmpty { return .fail("offset \(s) is past the end (\(total) lines)") }
        let more = e < total ? "\n(lines \(s)-\(e) of \(total); use offset \(e + 1) to read more)" : (s > 1 ? "\n(lines \(s)-\(e) of \(total))" : "")
        return .ok("\(ctx.rel(url)):\n" + body + more + (lossy ? "\n(note: not valid UTF-8; some characters are shown as �. Don't edit this file with edit_file: it would corrupt them.)" : ""))
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
    /// `url` relative to `root`, also when one of them goes through a symlink (/var vs /private/var, a linked project folder).
    nonisolated static func relative(_ url: URL, to root: URL) -> String {
        for r in [root, root.resolvingSymlinksInPath()] {
            let base = r.path.hasSuffix("/") ? r.path : r.path + "/"
            for u in [url, url.resolvingSymlinksInPath()] where u.path.hasPrefix(base) { return String(u.path.dropFirst(base.count)) }
        }
        return url.lastPathComponent
    }

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
        let candidates = pat.hasSuffix("/") ? await Task.detached { walk(root, includeDirs: true) }.value : await files(under: root, ctx: ctx)
        let hits = await Task.detached { () -> [(String, Date)] in
            candidates.compactMap { url in
                let rel = relative(url, to: root)
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
        let candidates = await files(under: root, ctx: ctx)
        let result = await Task.detached { () -> (lines: [String], files: Int, truncated: Bool, timedOut: Bool) in
            var lines: [String] = []
            var files = 0
            var truncated = false
            let deadline = Date().addingTimeInterval(25)
            var regexTimedOut = false
            /// One line against the pattern, abandoned at the deadline: a backtracking pattern like (a+)+$ can otherwise
            /// spin on a single short line for hours and freeze the whole agent.
            func hit(_ line: String) -> Bool {
                var found = false
                let lineDeadline = min(deadline, Date().addingTimeInterval(3))   // no single line gets more than 3 seconds
                re.enumerateMatches(in: line, options: [.reportProgress], range: NSRange(line.startIndex..., in: line)) { r, flags, stop in
                    if r != nil { found = true; stop.pointee = true }
                    else if flags.contains(.progress), Date() > lineDeadline { regexTimedOut = true; stop.pointee = true }
                }
                return found
            }
            let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
            for url in candidates {
                if Date() > deadline || regexTimedOut { truncated = true; break }
                let rel = relative(url, to: root)
                if let nameRE, !matches(nameRE, rel) { continue }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 3_000_000,
                      !data.prefix(4000).contains(0) else { continue }
                let text = String(decoding: data, as: UTF8.self)
                files += 1
                let all = text.components(separatedBy: "\n")
                let shownPath = Paths.display(url, root: projectRoot)
                var lastPrinted = -1
                for (i, line) in all.enumerated() where hit(line) {
                    let lo = max(0, i - context), hi = min(all.count - 1, i + context)
                    if context > 0 && lastPrinted >= 0 && lo > lastPrinted + 1 { lines.append("--") }
                    // Overlapping context windows (two matches near each other, or both clipped at the end of the file)
                    // leave nothing new to print.
                    let from = max(lo, lastPrinted + 1)
                    if from <= hi {
                        for k in from...hi {
                            let l = all[k].count > 240 ? String(all[k].prefix(240)) + "…" : all[k]
                            let isHit = k == i || hit(all[k])
                            lines.append("\(shownPath):\(k + 1)\(isHit ? ":" : "-") \(l)")
                        }
                    }
                    lastPrinted = max(lastPrinted, hi)
                    if lines.count >= limit { truncated = true; break }
                }
                if lines.count >= limit { break }
            }
            return (lines, files, truncated, regexTimedOut)
        }.value
        if result.timedOut { return .fail("the pattern /\(pat)/ ran past its time limit (catastrophic backtracking?). Use a simpler pattern, e.g. without nested repeats like (a+)+. Matches so far:\n" + result.lines.joined(separator: "\n")) }
        if result.lines.isEmpty { return .ok("no matches for /\(pat)/ in \(result.files) files under \(ctx.rel(root))") }
        return .ok(result.lines.joined(separator: "\n") + (result.truncated ? "\n(stopped at \(result.lines.count) lines; narrow path or glob)" : ""))
    }

    // MARK: Edits (prepared first, so the app can show the diff and ask)

    static func currentText(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readText(url, forEdit: true)
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

    static let replaceLines = ToolSpec(
        edit: "replace_lines",
        signature: #"{"path": str, "start": first line, "end": last line, "content": new text} or {"path": str, "ranges": [{"start", "end", "content"}, ...]}"#,
        summary: "replace whole lines by number in a file you read this session and that hasn't changed since (cheapest edit: no need to repeat the old text). Numbers refer to the file as you last saw it; content \"\" deletes the lines; \"insert\": true inserts before start"
    ) { a, ctx in
        guard let p = a["path"]?.string ?? a["file"]?.string else { throw ToolFailure("missing path") }
        let url = ctx.resolve(p)
        guard let text = try currentText(url) else { throw ToolFailure("\(ctx.rel(url)) doesn't exist; use write_file to create it") }
        let now = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let seen = ctx.readStamps[url.standardizedFileURL.path], seen == now else {
            throw ToolFailure("\(ctx.rel(url)) changed since you last read it (or you haven't read it). read_file it again, then use the new line numbers.")
        }
        struct R { var start: Int; var end: Int; var content: String; var insert: Bool }
        var ranges: [R] = []
        if let list = a["ranges"]?.array {
            for r in list {
                guard let st = r["start"]?.int, let c = r["content"]?.string ?? r["text"]?.string else { throw ToolFailure("each range needs start and content") }
                ranges.append(R(start: st, end: r["end"]?.int ?? st, content: c, insert: r["insert"]?.bool ?? false))
            }
        } else {
            guard let st = a["start"]?.int ?? a["start_line"]?.int ?? a["line"]?.int, let c = a["content"]?.string ?? a["text"]?.string ?? a["replace"]?.string
            else { throw ToolFailure("need start, end and content (or ranges)") }
            ranges.append(R(start: st, end: a["end"]?.int ?? a["end_line"]?.int ?? st, content: c, insert: a["insert"]?.bool ?? false))
        }
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = DiffEngine.lines(text)
        // Validate, then apply bottom-up so earlier numbers stay valid within this call.
        let sorted = ranges.sorted { $0.start > $1.start }
        for (i, r) in sorted.enumerated() {
            let maxStart = r.insert ? lines.count + 1 : lines.count
            guard r.start >= 1, r.start <= max(1, maxStart), r.insert || r.end >= r.start, r.insert || r.end <= lines.count else {
                throw ToolFailure("lines \(r.start)-\(r.end) are outside \(ctx.rel(url)) (it has \(lines.count) lines)")
            }
            if i > 0 && !r.insert && r.end >= sorted[i - 1].start { throw ToolFailure("ranges overlap; merge them") }
        }
        var shifts: [(Int, Int)] = []
        for r in sorted {
            let new = r.content.isEmpty ? [] : DiffEngine.lines(r.content.hasSuffix("\n") ? r.content : r.content + "\n")
            if r.insert {
                lines.insert(contentsOf: new, at: r.start - 1)
                shifts.append((r.start, new.count))
            } else {
                lines.replaceSubrange((r.start - 1)...(r.end - 1), with: new)
                shifts.append((r.end, new.count - (r.end - r.start + 1)))
            }
        }
        let net = shifts.reduce(0) { $0 + $1.1 }
        if net != 0, let lowest = shifts.map(\.0).min() {
            ctx.editNote = "(lines after \(lowest) moved by \(net > 0 ? "+" : "")\(net); use the new numbers for further edits)"
        }
        let out = lines.joined(separator: "\n") + (hadTrailingNewline || lines.isEmpty ? "\n" : "")
        if out == text { throw ToolFailure("no change: the content matches what's already there") }
        return [FileChange(url: url, old: text, new: out)]
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
