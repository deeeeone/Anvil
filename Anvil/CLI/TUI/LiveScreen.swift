import Foundation

/// Redraws only a small live region at the bottom of the terminal; everything else is printed once into scrollback.
///
/// Why: the flicker and scrollback corruption users complain about come from redrawing the whole screen. Here finished
/// output is written once with `commit` and never touched again. The live region (status line, streamed tail, input
/// box) is redrawn by moving the cursor up over it and rewriting only the rows that changed, inside synchronized-output
/// markers so the terminal shows each frame atomically. No alternate screen, no full clears, no absolute positioning,
/// so native scrollback and text selection keep working.
///
/// Invariant: `cursorRow` is where the physical cursor sits, counted from the region's top row. Every move back to the
/// top uses it, so it must be updated after each write.
final class LiveScreen {
    /// False when stdout is not a terminal: commits print plain text and live updates are dropped.
    let interactive: Bool
    private let write: (String) -> Void
    private let size: () -> (cols: Int, rows: Int)

    /// The unwrapped lines last given to setLive, kept so `resized()` can re-wrap them at the new width.
    private var liveSource: [String] = []
    /// The cursor given with `liveSource`, before wrapping.
    private var liveSourceCursor: (row: Int, col: Int)?
    /// Rows currently on screen, already wrapped to the width they were drawn at.
    private var liveRows: [String] = []
    /// Physical cursor row, counted from the region's top row.
    private var cursorRow = 0
    /// Cursor position within the wrapped rows, or nil when the cursor is hidden.
    private var lastCursor: (row: Int, col: Int)?
    /// Last cursor visibility written (nil before the first write).
    private var cursorVisible: Bool?

    private var pending: (lines: [String], cursor: (row: Int, col: Int)?)?
    private var flushScheduled = false

    init(interactive: Bool, write: @escaping (String) -> Void, size: @escaping () -> (cols: Int, rows: Int)) {
        self.interactive = interactive
        self.write = write
        self.size = size
    }

    /// Prints finished lines into scrollback above the live region, then redraws the region below them. The lines
    /// are wrapped to one column less than the terminal width so the terminal never wraps on its own. One write.
    func commit(_ lines: [String]) {
        guard interactive else {
            var plain = ""
            for line in lines { plain += Ansi.stripped(line) + "\n" }
            if !plain.isEmpty { write(plain) }
            return
        }
        let width = max(1, size().cols - 1)
        var newRows = liveRows
        if let p = pending {
            pending = nil
            liveSource = p.lines
            liveSourceCursor = p.cursor
            let prepared = prepare(p.lines, cursor: p.cursor)
            newRows = prepared.rows
            lastCursor = prepared.cursor
        }

        var s = "\u{1B}[?2026h"
        s += moveUp(cursorRow) + "\r\u{1B}[J"
        for line in lines {
            for row in Ansi.wrap(line, width: width) {
                s += row + "\r\n"
            }
        }
        let drawn = frame(prev: [], prevCursor: 0, new: newRows, cursor: lastCursor)
        s += drawn.body + visibility(lastCursor != nil) + "\u{1B}[?2026l"
        write(s)
        liveRows = newRows
        cursorRow = drawn.top
    }

    /// Replaces the live region. The lines are wrapped to the width and capped to the height (the last lines win),
    /// and the cursor is placed at `cursor` (row and column counted in the given lines) or hidden when nil.
    /// Draws immediately; use `setLiveThrottled` when calls come many times a second.
    func setLive(_ lines: [String], cursor: (row: Int, col: Int)?) {
        pending = nil
        guard interactive else { return }
        drawLive(lines, cursor: cursor)
    }

    /// Like `setLive`, but coalesces: the latest frame is kept and drawn at most once per ~33 ms.
    func setLiveThrottled(_ lines: [String], cursor: (row: Int, col: Int)?) {
        guard interactive else { return }
        pending = (lines, cursor)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            self?.flush()
        }
    }

    /// Draws the pending throttled frame now, if there is one.
    func flush() {
        flushScheduled = false
        guard let p = pending else { return }
        pending = nil
        drawLive(p.lines, cursor: p.cursor)
    }

    /// Call after the terminal size changed. The rows on screen are moved over using their physical height at the new
    /// width (a row of display width w takes ceil(w / cols) rows), then the region is redrawn from scratch.
    /// Why the physical count: each row was written with a hard line break, so a reflowing terminal still shows it as
    /// its own row(s) after a widen, and a re-wrap would undercount and leave stale rows behind. A narrow reflows rows
    /// that are wider than the new width. Assumes a terminal that reflows soft-wrapped text, which most modern ones do.
    func resized() {
        guard interactive else { return }
        pending = nil
        let columns = max(1, size().cols)
        func height(_ row: String) -> Int { max(1, (Ansi.displayWidth(row) + columns - 1) / columns) }
        var up = liveRows.prefix(cursorRow).reduce(0) { $0 + height($1) }
        if cursorRow < liveRows.count {
            up += lastCursor.map { $0.col / columns } ?? (height(liveRows[cursorRow]) - 1)
        }
        let prepared = prepare(liveSource, cursor: liveSourceCursor)
        var s = "\u{1B}[?2026h" + moveUp(up) + "\r\u{1B}[J"
        let drawn = frame(prev: [], prevCursor: 0, new: prepared.rows, cursor: prepared.cursor)
        s += drawn.body + visibility(prepared.cursor != nil) + "\u{1B}[?2026l"
        write(s)
        liveRows = prepared.rows
        lastCursor = prepared.cursor
        cursorRow = drawn.top
    }

    /// Erases the live region and leaves the cursor at the place it occupied, with the cursor shown.
    func clearLive() {
        pending = nil
        guard interactive else { return }
        write(moveUp(cursorRow) + "\r\u{1B}[J" + visibility(true))
        liveRows = []
        liveSource = []
        liveSourceCursor = nil
        lastCursor = nil
        cursorRow = 0
    }

    /// Freezes the live region as permanent output and leaves the cursor on a fresh line below everything.
    func finish() {
        pending = nil
        guard interactive else { return }
        var s = ""
        if !liveRows.isEmpty {
            let down = liveRows.count - 1 - cursorRow
            s += String(repeating: "\r\n", count: max(0, down)) + "\r\n"
        }
        s += visibility(true)
        write(s)
        liveRows = []
        liveSource = []
        liveSourceCursor = nil
        lastCursor = nil
        cursorRow = 0
    }

    // MARK: - Internals

    private func drawLive(_ lines: [String], cursor: (row: Int, col: Int)?) {
        let prepared = prepare(lines, cursor: cursor)
        let drawn = frame(prev: liveRows, prevCursor: cursorRow, new: prepared.rows, cursor: prepared.cursor)
        write("\u{1B}[?2026h" + drawn.body + visibility(prepared.cursor != nil) + "\u{1B}[?2026l")
        liveSource = lines
        liveSourceCursor = cursor
        liveRows = prepared.rows
        cursorRow = drawn.top
        lastCursor = prepared.cursor
    }

    /// Wraps the lines to the current width and caps the result to the screen height. The cursor is mapped onto the
    /// wrapped rows. A cursor past the last line lands at the end of the last row.
    private func prepare(_ lines: [String], cursor: (row: Int, col: Int)?) -> (rows: [String], cursor: (row: Int, col: Int)?) {
        let (cols, screenRows) = size()
        let width = max(1, cols - 1)
        var rows: [String] = []
        var mapped: (row: Int, col: Int)?
        for (index, line) in lines.enumerated() {
            let wrapped = Ansi.wrap(line, width: width)
            if let c = cursor, c.row == index {
                let sub = min(max(0, c.col) / width, wrapped.count - 1)
                mapped = (rows.count + sub, max(0, c.col) - sub * width)
            }
            rows += wrapped
        }
        if let c = cursor, mapped == nil, !rows.isEmpty {
            mapped = (rows.count - 1, min(max(0, c.col), width - 1))
        }
        let maxRows = max(1, screenRows - 1)
        if rows.count > maxRows {
            let drop = rows.count - maxRows
            rows = Array(rows.suffix(maxRows))
            if let m = mapped { mapped = (m.row - drop, m.col) }
        }
        if rows.isEmpty {
            return ([], nil)
        }
        if let m = mapped {
            mapped = (min(max(0, m.row), rows.count - 1), m.col)
        }
        return (rows, mapped)
    }

    /// The escape sequences that take the screen from `prev` (drawn, cursor on row `prevCursor`) to `new`. The region
    /// top is assumed to be `prevCursor` rows above the cursor. Returns the body and the cursor row it ends on.
    private func frame(prev: [String], prevCursor: Int, new: [String], cursor: (row: Int, col: Int)?) -> (body: String, top: Int) {
        var s = moveUp(prevCursor) + "\r"
        for (index, row) in new.enumerated() {
            if index > 0 { s += "\r\n" }
            if index >= prev.count || prev[index] != row {
                s += "\u{1B}[2K" + row
            }
        }
        var at = max(0, new.count - 1)
        if new.isEmpty {
            s += "\u{1B}[J"
        } else if prev.count > new.count {
            // Rows left over from a taller region: step below the new bottom and clear everything under it.
            s += "\r\n\u{1B}[J"
            at = new.count
        }
        let target = cursor.map { min(max(0, $0.row), max(0, new.count - 1)) } ?? max(0, new.count - 1)
        s += moveUp(at - target) + "\r"
        if let c = cursor, c.col > 0 {
            s += "\u{1B}[\(c.col)C"
        }
        return (s, target)
    }

    /// Moves up `n` rows, emitting nothing for zero (ESC[0A would be read as one row by some terminals).
    private func moveUp(_ n: Int) -> String {
        n > 0 ? "\u{1B}[\(n)A" : ""
    }

    /// Shows or hides the cursor, writing only on change.
    private func visibility(_ visible: Bool) -> String {
        if cursorVisible == visible { return "" }
        cursorVisible = visible
        return visible ? "\u{1B}[?25h" : "\u{1B}[?25l"
    }
}
