import Foundation

/// What the caller should do after a key went through the editor.
nonisolated enum EditorAction: Equatable {
    case none
    case changed
    case submit(String)
    case cancel
    case eof
}

/// Single- and multi-line input buffer with history, as a pure state machine.
/// Why it is pure: the editing rules can be tested without a terminal, and the renderer only ever sees the result
/// (`render`). The cursor is an index into `chars`, so wide characters and combining marks never split.
nonisolated struct LineEditor {
    static let historyLimit = 500

    private(set) var chars: [Character] = []
    /// Index into `chars` (a Character offset, not a byte or String.Index).
    private(set) var cursor = 0
    /// Previously submitted lines, oldest first. Up and Down browse them when the cursor is on the first or last line.
    var history: [String] = []
    /// Dim hint shown when the buffer is empty.
    var placeholder = ""
    /// Tab completion. Receives the text and the cursor index and returns full replacements for the current token.
    var complete: ((String, Int) -> [String])?
    /// The candidates from the last ambiguous Tab, for the UI to list.
    private(set) var candidates: [String] = []

    private var browseIndex: Int?
    private var draft: [Character] = []

    init() {}

    var text: String { String(chars) }
    var isEmpty: Bool { chars.isEmpty }

    /// Replaces the buffer, for example to prefill it. The cursor goes to the end.
    mutating func setText(_ s: String) {
        chars = Array(s)
        cursor = chars.count
        browseIndex = nil
        candidates = []
    }

    mutating func handle(_ key: Key) -> EditorAction {
        if key != .tab { candidates = [] }
        switch key {
        case .char(let c):
            insert([c])
            return .changed
        case .paste(let s):
            if s.isEmpty { return .none }
            insert(Array(s))
            return .changed
        case .enter:
            return enter()
        case .altEnter:
            insert(["\n"])
            return .changed
        case .ctrl(let c):
            return ctrl(c)
        case .backspace:
            return deleteBackward()
        case .delete:
            return deleteForward()
        case .left:
            return moveLeft()
        case .right:
            return moveRight()
        case .home:
            return moveHome()
        case .end:
            return moveEnd()
        case .up:
            return moveUp()
        case .down:
            return moveDown()
        case .tab:
            return completeToken()
        case .shiftTab, .escape, .pageUp, .pageDown, .unknown:
            return .none
        }
    }

    // MARK: - Editing

    private mutating func insert(_ new: [Character]) {
        chars.insert(contentsOf: new, at: cursor)
        cursor += new.count
    }

    private mutating func deleteBackward() -> EditorAction {
        guard cursor > 0 else { return .none }
        chars.remove(at: cursor - 1)
        cursor -= 1
        return .changed
    }

    private mutating func deleteForward() -> EditorAction {
        guard cursor < chars.count else { return .none }
        chars.remove(at: cursor)
        return .changed
    }

    private mutating func enter() -> EditorAction {
        // A trailing backslash turns Enter into a newline, the shell convention for continuing a line.
        if cursor > 0 && chars[cursor - 1] == "\\" {
            chars[cursor - 1] = "\n"
            return .changed
        }
        var end = chars.count
        while end > 0 && chars[end - 1] == "\n" { end -= 1 }
        let submitted = String(chars[0..<end])
        if submitted.allSatisfy({ $0.isWhitespace }) { return .none }
        if history.last != submitted {
            history.append(submitted)
            if history.count > LineEditor.historyLimit {
                history.removeFirst(history.count - LineEditor.historyLimit)
            }
        }
        chars = []
        cursor = 0
        browseIndex = nil
        draft = []
        return .submit(submitted)
    }

    private mutating func ctrl(_ c: Character) -> EditorAction {
        switch c {
        case "c":
            if !chars.isEmpty {
                chars = []
                cursor = 0
                browseIndex = nil
                return .changed
            }
            return .cancel
        case "d":
            if chars.isEmpty { return .eof }
            return deleteForward()
        case "j":
            insert(["\n"])
            return .changed
        case "a": return moveHome()
        case "e": return moveEnd()
        case "b": return moveLeft()
        case "f": return moveRight()
        case "p": return moveUp()
        case "n": return moveDown()
        case "h": return deleteBackward()
        case "k":
            let end = lineEnd(cursor)
            if end > cursor {
                chars.removeSubrange(cursor..<end)
                return .changed
            }
            // At the end of a line, Ctrl-K joins the next line, as in Emacs.
            return deleteForward()
        case "u":
            let start = lineStart(cursor)
            guard start < cursor else { return .none }
            chars.removeSubrange(start..<cursor)
            cursor = start
            return .changed
        case "w":
            var p = cursor
            while p > 0 && chars[p - 1].isWhitespace { p -= 1 }
            while p > 0 && !chars[p - 1].isWhitespace { p -= 1 }
            guard p < cursor else { return .none }
            chars.removeSubrange(p..<cursor)
            cursor = p
            return .changed
        default:
            return .none
        }
    }

    // MARK: - Movement

    private func lineStart(_ pos: Int) -> Int {
        var p = pos
        while p > 0 && chars[p - 1] != "\n" { p -= 1 }
        return p
    }

    private func lineEnd(_ pos: Int) -> Int {
        var p = pos
        while p < chars.count && chars[p] != "\n" { p += 1 }
        return p
    }

    private mutating func moveLeft() -> EditorAction {
        guard cursor > 0 else { return .none }
        cursor -= 1
        return .changed
    }

    private mutating func moveRight() -> EditorAction {
        guard cursor < chars.count else { return .none }
        cursor += 1
        return .changed
    }

    private mutating func moveHome() -> EditorAction {
        let start = lineStart(cursor)
        guard start != cursor else { return .none }
        cursor = start
        return .changed
    }

    private mutating func moveEnd() -> EditorAction {
        let end = lineEnd(cursor)
        guard end != cursor else { return .none }
        cursor = end
        return .changed
    }

    /// Up moves to the line above (same column, clamped), or browses older history on the first line.
    private mutating func moveUp() -> EditorAction {
        let start = lineStart(cursor)
        guard start > 0 else { return browseOlder() }
        let column = cursor - start
        let previousEnd = start - 1
        let previousStart = lineStart(previousEnd)
        cursor = previousStart + min(column, previousEnd - previousStart)
        return .changed
    }

    /// Down moves to the line below, or browses newer history (ending at the draft) on the last line.
    private mutating func moveDown() -> EditorAction {
        let end = lineEnd(cursor)
        guard end < chars.count else { return browseNewer() }
        let column = cursor - lineStart(cursor)
        let nextStart = end + 1
        let nextEnd = lineEnd(nextStart)
        cursor = nextStart + min(column, nextEnd - nextStart)
        return .changed
    }

    private mutating func browseOlder() -> EditorAction {
        guard !history.isEmpty else { return .none }
        if browseIndex == nil {
            draft = chars
            browseIndex = history.count
        }
        guard let index = browseIndex, index > 0 else { return .none }
        browseIndex = index - 1
        chars = Array(history[index - 1])
        cursor = chars.count
        return .changed
    }

    private mutating func browseNewer() -> EditorAction {
        guard let index = browseIndex else { return .none }
        if index + 1 < history.count {
            browseIndex = index + 1
            chars = Array(history[index + 1])
        } else {
            browseIndex = nil
            chars = draft
        }
        cursor = chars.count
        return .changed
    }

    // MARK: - Completion

    private mutating func completeToken() -> EditorAction {
        guard let complete else { return .none }
        let candidatesNow = complete(text, cursor)
        guard !candidatesNow.isEmpty else {
            candidates = []
            return .none
        }
        var start = cursor
        while start > 0 && !chars[start - 1].isWhitespace { start -= 1 }
        if candidatesNow.count == 1 {
            replace(start..<cursor, with: candidatesNow[0])
            candidates = []
            return .changed
        }
        candidates = candidatesNow
        let prefix = LineEditor.commonPrefix(candidatesNow)
        guard prefix.count > cursor - start else { return .none }
        replace(start..<cursor, with: prefix)
        return .changed
    }

    private mutating func replace(_ range: Range<Int>, with s: String) {
        let new = Array(s)
        chars.replaceSubrange(range, with: new)
        cursor = range.lowerBound + new.count
    }

    static func commonPrefix(_ items: [String]) -> String {
        guard var prefix = items.first.map({ Array($0) }) else { return "" }
        for item in items.dropFirst() {
            let other = Array(item)
            var k = 0
            while k < prefix.count && k < other.count && prefix[k] == other[k] { k += 1 }
            prefix = Array(prefix[0..<k])
        }
        return String(prefix)
    }

    // MARK: - Rendering

    /// Lays the buffer out for a `width`-column area. The first logical line starts with `prompt`, later lines with
    /// `continuation`, and wrapped rows are indented to the prefix width. The cursor position is in those rows.
    func render(width: Int, prompt: String, continuation: String) -> (lines: [String], cursorRow: Int, cursorCol: Int) {
        let width = max(1, width)
        if chars.isEmpty && !placeholder.isEmpty {
            let promptWidth = Ansi.displayWidth(prompt)
            let hint = Ansi.truncate(placeholder, width: max(1, width - promptWidth))
            return ([prompt + Ansi.dim(hint)], 0, min(promptWidth, width - 1))
        }

        var out: [String] = []
        var indent = Ansi.displayWidth(prompt)
        var row = prompt
        var w = indent
        var cursorRow = 0
        var cursorCol = 0
        var i = 0
        while true {
            if i == chars.count {
                if cursor == i {
                    cursorRow = out.count
                    cursorCol = w
                }
                break
            }
            let ch = chars[i]
            if ch == "\n" {
                if cursor == i {
                    cursorRow = out.count
                    cursorCol = w
                }
                out.append(row)
                indent = Ansi.displayWidth(continuation)
                row = continuation
                w = indent
                i += 1
                continue
            }
            let cw = Ansi.cellWidth(of: ch)
            if w + cw > width && w > indent {
                out.append(row)
                row = String(repeating: " ", count: indent)
                w = indent
            }
            if cursor == i {
                cursorRow = out.count
                cursorCol = w
            }
            row.append(ch)
            w += cw
            i += 1
        }
        out.append(row)
        return (out, cursorRow, cursorCol)
    }
}

/// Command history stored as JSON lines (one JSON string per line), so entries with newlines stay on one line.
nonisolated struct History {
    static let limit = 500
    private(set) var entries: [String] = []

    init(entries: [String] = []) {
        self.entries = Array(entries.suffix(History.limit))
    }

    mutating func append(_ s: String) {
        guard !s.isEmpty, entries.last != s else { return }
        entries.append(s)
        if entries.count > History.limit { entries.removeFirst(entries.count - History.limit) }
    }

    /// Reads the file. A missing file or a broken line leaves the history as it was for that line.
    mutating func load(from url: URL) {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
        var loaded: [String] = []
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(String.self, from: lineData) else { continue }
            loaded.append(entry)
        }
        entries = Array(loaded.suffix(History.limit))
    }

    func save(to url: URL) throws {
        var text = ""
        for entry in entries {
            let encoded = try JSONEncoder().encode(entry)
            text += String(decoding: encoded, as: UTF8.self) + "\n"
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
