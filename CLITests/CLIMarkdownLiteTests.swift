import XCTest
@testable import AnvilCore

final class CLIMarkdownLiteTests: XCTestCase {
    /// Assertions compare the text without styles, so they hold whether or not the test terminal is colored.
    private func plain(_ text: String, width: Int = 80) -> [String] {
        MarkdownLite.render(text, width: width).map { Ansi.stripped($0) }
    }

    func testHeadingBecomesBoldTextWithoutHashes() {
        XCTAssertEqual(plain("# Title"), ["Title"])
        XCTAssertEqual(plain("### Smaller"), ["Smaller"])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(plain("#hashtag"), ["#hashtag"])
    }

    func testBoldMarkersAreRemoved() {
        XCTAssertEqual(plain("a **bold** word"), ["a bold word"])
    }

    func testUnpairedBoldMarkerStaysAsWritten() {
        XCTAssertEqual(plain("2 ** 3"), ["2 ** 3"])
    }

    func testInlineCodeLosesItsBackticks() {
        XCTAssertEqual(plain("run `swift test` now"), ["run swift test now"])
    }

    func testUnclosedBacktickStaysLiteral() {
        XCTAssertEqual(plain("odd ` tick"), ["odd ` tick"])
    }

    func testFencedCodeIsIndentedWithAGutter() {
        let out = plain("before\n```swift\nlet x = 1\n```\nafter")
        XCTAssertEqual(out, ["before", "  │ let x = 1", "after"])
    }

    func testFenceMarkersAreNotShown() {
        XCTAssertFalse(plain("```\ncode\n```").contains { $0.contains("```") })
    }

    func testListMarkersAreKept() {
        XCTAssertEqual(plain("- one\n* two\n1. three"), ["- one", "* two", "1. three"])
    }

    func testLinkShowsTextAndURL() {
        XCTAssertEqual(plain("see [the docs](https://example.com/docs) here"),
                       ["see the docs (https://example.com/docs) here"])
    }

    func testLongParagraphWrapsToWidth() {
        let rows = plain("alpha beta gamma delta epsilon zeta eta theta", width: 20)
        XCTAssertGreaterThan(rows.count, 1)
        for row in rows { XCTAssertLessThanOrEqual(Ansi.displayWidth(row), 20) }
    }

    func testTrailingBlankLinesAreDropped() {
        XCTAssertEqual(plain("text\n\n\n"), ["text"])
    }

    func testEmptyTextRendersNothing() {
        XCTAssertEqual(MarkdownLite.render("", width: 40), [])
    }
}
