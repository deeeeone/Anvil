import XCTest
@testable import AnvilCore

final class TUIAnsiTests: XCTestCase {
    func testDisplayWidthOfPlainAndCombining() {
        XCTAssertEqual(Ansi.displayWidth("a"), 1)
        XCTAssertEqual(Ansi.displayWidth("\u{00E9}"), 1)          // precomposed é
        XCTAssertEqual(Ansi.displayWidth("e\u{0301}"), 1)        // e + combining acute
        XCTAssertEqual(Ansi.displayWidth("abc"), 3)
    }

    func testDisplayWidthOfWideAndEmoji() {
        XCTAssertEqual(Ansi.displayWidth("漢"), 2)
        XCTAssertEqual(Ansi.displayWidth("漢字"), 4)
        XCTAssertEqual(Ansi.displayWidth("👍"), 2)
        XCTAssertEqual(Ansi.displayWidth("❤\u{FE0F}"), 2)
    }

    func testDisplayWidthIgnoresStyles() {
        XCTAssertEqual(Ansi.displayWidth("\u{1B}[1mab\u{1B}[0m"), 2)
        XCTAssertEqual(Ansi.displayWidth("\u{1B}[38;5;196mred\u{1B}[0m"), 3)
    }

    func testStrippedRemovesEscapes() {
        XCTAssertEqual(Ansi.stripped("\u{1B}[31mhi\u{1B}[0m there"), "hi there")
    }

    func testWrapKeepsStylesOpenAcrossLines() {
        let rows = Ansi.wrap("\u{1B}[31mhello world\u{1B}[0m", width: 5)
        XCTAssertGreaterThanOrEqual(rows.count, 2)
        for row in rows {
            XCTAssertLessThanOrEqual(Ansi.displayWidth(row), 5)
        }
        for row in rows.dropFirst() {
            XCTAssertTrue(row.hasPrefix("\u{1B}[31m"), "continuation lost its style: \(row.debugDescription)")
        }
        XCTAssertTrue(rows.dropLast().allSatisfy { $0.hasSuffix("\u{1B}[0m") })
        XCTAssertEqual(rows.map { Ansi.stripped($0) }.joined(), "hello world")
    }

    func testWrapSplitsOnNewlines() {
        XCTAssertEqual(Ansi.wrap("a\nb", width: 10), ["a", "b"])
        XCTAssertEqual(Ansi.wrap("", width: 10), [""])
    }

    func testWrapDoesNotSplitWideCharacters() {
        let rows = Ansi.wrap("漢字漢", width: 3)
        XCTAssertEqual(rows, ["漢", "字", "漢"])
    }

    func testTruncateAddsEllipsis() {
        let cut = Ansi.truncate("hello world", width: 6)
        XCTAssertEqual(cut, "hello\u{2026}")
        XCTAssertEqual(Ansi.displayWidth(cut), 6)
    }

    func testTruncateLeavesShortStringsAlone() {
        XCTAssertEqual(Ansi.truncate("hi", width: 10), "hi")
        XCTAssertEqual(Ansi.truncate("hello", width: 0), "")
    }

    func testTruncateClosesOpenStyle() {
        let cut = Ansi.truncate("\u{1B}[1mhello world\u{1B}[0m", width: 4)
        XCTAssertEqual(Ansi.stripped(cut), "hel\u{2026}")
        XCTAssertTrue(cut.hasSuffix("\u{1B}[0m"))
    }

    func testSpinnerElapsedFormat() {
        XCTAssertEqual(Spinner.elapsed(12), "12s")
        XCTAssertEqual(Spinner.elapsed(65), "1m 05s")
        XCTAssertEqual(Spinner.elapsed(-3), "0s")
    }
}
