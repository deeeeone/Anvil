import XCTest
@testable import AnvilCore

final class TUILineEditorTests: XCTestCase {
    private func type(_ editor: inout LineEditor, _ s: String) {
        for ch in s { _ = editor.handle(.char(ch)) }
    }

    func testInsertDeleteAndMove() {
        var e = LineEditor()
        type(&e, "abc")
        XCTAssertEqual(e.text, "abc")
        _ = e.handle(.left)
        _ = e.handle(.backspace)
        XCTAssertEqual(e.text, "ac")
        XCTAssertEqual(e.cursor, 1)
        _ = e.handle(.delete)
        XCTAssertEqual(e.text, "a")
        _ = e.handle(.home)
        type(&e, "x")
        XCTAssertEqual(e.text, "xa")
        _ = e.handle(.end)
        XCTAssertEqual(e.cursor, 2)
    }

    func testEnterSubmitsAndRecordsHistory() {
        var e = LineEditor()
        type(&e, "hello")
        XCTAssertEqual(e.handle(.enter), .submit("hello"))
        XCTAssertEqual(e.text, "")
        XCTAssertEqual(e.history, ["hello"])
    }

    func testEmptyEnterSubmitsNothing() {
        var e = LineEditor()
        XCTAssertEqual(e.handle(.enter), .none)
        XCTAssertTrue(e.history.isEmpty)
    }

    func testNoConsecutiveDuplicateHistory() {
        var e = LineEditor()
        for _ in 0..<2 {
            type(&e, "same")
            _ = e.handle(.enter)
        }
        XCTAssertEqual(e.history, ["same"])
    }

    func testBackslashEnterContinuesTheLine() {
        var e = LineEditor()
        type(&e, "a\\")
        XCTAssertEqual(e.handle(.enter), .changed)
        XCTAssertEqual(e.text, "a\n")
        type(&e, "b")
        XCTAssertEqual(e.handle(.enter), .submit("a\nb"))
    }

    func testAltEnterAndCtrlJInsertNewlines() {
        var e = LineEditor()
        type(&e, "one")
        XCTAssertEqual(e.handle(.altEnter), .changed)
        type(&e, "two")
        _ = e.handle(.ctrl("j"))
        type(&e, "3")
        XCTAssertEqual(e.text, "one\ntwo\n3")
    }

    func testPasteInsertsVerbatimAndNeverSubmits() {
        var e = LineEditor()
        XCTAssertEqual(e.handle(.paste("line1\nline2")), .changed)
        XCTAssertEqual(e.text, "line1\nline2")
        XCTAssertEqual(e.handle(.paste("")), .none)
    }

    func testHistoryBrowseRestoresDraft() {
        var e = LineEditor()
        e.history = ["one", "two"]
        type(&e, "draft")
        _ = e.handle(.up)
        XCTAssertEqual(e.text, "two")
        _ = e.handle(.up)
        XCTAssertEqual(e.text, "one")
        _ = e.handle(.up)
        XCTAssertEqual(e.text, "one", "oldest entry stays put")
        _ = e.handle(.down)
        XCTAssertEqual(e.text, "two")
        _ = e.handle(.down)
        XCTAssertEqual(e.text, "draft")
    }

    func testUpMovesWithinMultilineBeforeBrowsing() {
        var e = LineEditor()
        e.history = ["old"]
        type(&e, "ab")
        _ = e.handle(.altEnter)
        type(&e, "cd")
        XCTAssertEqual(e.handle(.up), .changed)
        XCTAssertEqual(e.text, "ab\ncd", "up on the second line moves to the first, no history")
        XCTAssertEqual(e.cursor, 2, "column is clamped to the shorter line")
    }

    func testCtrlCClearsThenCancels() {
        var e = LineEditor()
        type(&e, "text")
        XCTAssertEqual(e.handle(.ctrl("c")), .changed)
        XCTAssertEqual(e.text, "")
        XCTAssertEqual(e.handle(.ctrl("c")), .cancel)
    }

    func testCtrlDOnEmptyIsEOFOtherwiseDeletes() {
        var e = LineEditor()
        XCTAssertEqual(e.handle(.ctrl("d")), .eof)
        type(&e, "x")
        _ = e.handle(.home)
        XCTAssertEqual(e.handle(.ctrl("d")), .changed)
        XCTAssertEqual(e.text, "")
    }

    func testKillCommands() {
        var e = LineEditor()
        e.setText("hello big world")
        _ = e.handle(.ctrl("w"))
        XCTAssertEqual(e.text, "hello big ")
        _ = e.handle(.ctrl("u"))
        XCTAssertEqual(e.text, "")

        e.setText("abc def")
        _ = e.handle(.home)
        _ = e.handle(.right)
        _ = e.handle(.right)
        _ = e.handle(.right)
        _ = e.handle(.right)
        XCTAssertEqual(e.cursor, 4)
        _ = e.handle(.ctrl("k"))
        XCTAssertEqual(e.text, "abc ")

        e.setText("x\ny")
        _ = e.handle(.home)
        XCTAssertEqual(e.cursor, 2, "home goes to the start of the current line")
    }

    func testCtrlAAndCtrlEWorkOnTheCurrentLine() {
        var e = LineEditor()
        e.setText("first\nsecond")
        _ = e.handle(.ctrl("a"))
        XCTAssertEqual(e.cursor, 6, "start of 'second', not the buffer start")
        _ = e.handle(.ctrl("e"))
        XCTAssertEqual(e.cursor, 12)
    }

    func testTabWithOneCandidateReplacesToken() {
        var e = LineEditor()
        e.complete = { text, cursor in
            let token = String(text.prefix(cursor).split(separator: " ").last ?? "")
            return ["checkout", "cherry"].filter { $0.hasPrefix(token) && token == "chec" }
        }
        type(&e, "git chec")
        XCTAssertEqual(e.handle(.tab), .changed)
        XCTAssertEqual(e.text, "git checkout")
        XCTAssertTrue(e.candidates.isEmpty)
    }

    func testTabWithSeveralCandidatesInsertsCommonPrefix() {
        var e = LineEditor()
        e.complete = { _, _ in ["build", "bundle"] }
        type(&e, "b")
        XCTAssertEqual(e.handle(.tab), .changed)
        XCTAssertEqual(e.text, "bu")
        XCTAssertEqual(e.candidates, ["build", "bundle"])
    }

    func testRenderPlacesCursorWithWideCharacters() {
        var e = LineEditor()
        type(&e, "漢字")
        let r = e.render(width: 10, prompt: "> ", continuation: "  ")
        XCTAssertEqual(r.lines, ["> 漢字"])
        XCTAssertEqual(r.cursorRow, 0)
        XCTAssertEqual(r.cursorCol, 6)
    }

    func testRenderWrapsByWidth() {
        var e = LineEditor()
        type(&e, "abcdef")
        let r = e.render(width: 4, prompt: "", continuation: "")
        XCTAssertEqual(r.lines, ["abcd", "ef"])
        XCTAssertEqual(r.cursorRow, 1)
        XCTAssertEqual(r.cursorCol, 2)
    }

    func testRenderWrapsWideCharactersWithoutSplitting() {
        var e = LineEditor()
        type(&e, "漢字漢")
        let r = e.render(width: 4, prompt: "", continuation: "")
        XCTAssertEqual(r.lines, ["漢字", "漢"])
        XCTAssertEqual(r.cursorRow, 1)
        XCTAssertEqual(r.cursorCol, 2)
    }

    func testRenderMultilineUsesContinuationPrefix() {
        var e = LineEditor()
        type(&e, "a")
        _ = e.handle(.altEnter)
        type(&e, "b")
        let r = e.render(width: 20, prompt: "$ ", continuation: "> ")
        XCTAssertEqual(r.lines, ["$ a", "> b"])
        XCTAssertEqual(r.cursorRow, 1)
        XCTAssertEqual(r.cursorCol, 3)
    }

    func testPlaceholderWhenEmpty() {
        var e = LineEditor()
        e.placeholder = "type here"
        let r = e.render(width: 40, prompt: "> ", continuation: "  ")
        XCTAssertEqual(r.lines.count, 1)
        XCTAssertEqual(Ansi.stripped(r.lines[0]), "> type here")
        XCTAssertEqual(r.cursorCol, 2)
    }

    func testHistoryRoundTripsThroughFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tui-history-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var h = History()
        h.append("first")
        h.append("multi\nline")
        h.append("first")
        h.append("first")
        XCTAssertEqual(h.entries, ["first", "multi\nline", "first"])
        try h.save(to: url)
        var loaded = History()
        loaded.load(from: url)
        XCTAssertEqual(loaded.entries, ["first", "multi\nline", "first"])
    }
}
