import XCTest
@testable import AnvilCore

final class TUIKeysTests: XCTestCase {
    private func keys(_ s: String) -> [Key] {
        var parser = KeyParser()
        return parser.feed(Array(s.utf8)) + parser.flushPendingEscape()
    }

    func testArrowsAndNavigationKeys() {
        XCTAssertEqual(keys("\u{1B}[A"), [.up])
        XCTAssertEqual(keys("\u{1B}[B"), [.down])
        XCTAssertEqual(keys("\u{1B}[C"), [.right])
        XCTAssertEqual(keys("\u{1B}[D"), [.left])
        XCTAssertEqual(keys("\u{1B}[H"), [.home])
        XCTAssertEqual(keys("\u{1B}[F"), [.end])
        XCTAssertEqual(keys("\u{1B}OH"), [.home])
        XCTAssertEqual(keys("\u{1B}OF"), [.end])
        XCTAssertEqual(keys("\u{1B}[Z"), [.shiftTab])
    }

    func testTildeSequences() {
        XCTAssertEqual(keys("\u{1B}[1~"), [.home])
        XCTAssertEqual(keys("\u{1B}[7~"), [.home])
        XCTAssertEqual(keys("\u{1B}[4~"), [.end])
        XCTAssertEqual(keys("\u{1B}[8~"), [.end])
        XCTAssertEqual(keys("\u{1B}[3~"), [.delete])
        XCTAssertEqual(keys("\u{1B}[5~"), [.pageUp])
        XCTAssertEqual(keys("\u{1B}[6~"), [.pageDown])
    }

    func testModifiedSequencesUseTheBaseKey() {
        XCTAssertEqual(keys("\u{1B}[1;5C"), [.right])
        XCTAssertEqual(keys("\u{1B}[1;2A"), [.up])
        XCTAssertEqual(keys("\u{1B}[3;5~"), [.delete])
    }

    func testUTF8SplitAcrossFeeds() {
        var parser = KeyParser()
        // U+6F22 (漢) is E6 BC A2.
        XCTAssertEqual(parser.feed([0xE6]), [])
        XCTAssertEqual(parser.feed([0xBC]), [])
        XCTAssertEqual(parser.feed([0xA2]), [.char("漢")])
    }

    func testMultibyteCharacterInOneFeed() {
        XCTAssertEqual(keys("é"), [.char("é")])
    }

    func testEnterVariantsAndEditingBytes() {
        XCTAssertEqual(keys("\r"), [.enter])
        XCTAssertEqual(keys("\n"), [.enter])
        XCTAssertEqual(keys("\u{1B}\r"), [.altEnter])
        XCTAssertEqual(keys("\u{7F}"), [.backspace])
        XCTAssertEqual(keys("\u{08}"), [.backspace])
        XCTAssertEqual(keys("\t"), [.tab])
    }

    func testControlLetters() {
        XCTAssertEqual(keys("\u{03}"), [.ctrl("c")])
        XCTAssertEqual(keys("\u{01}"), [.ctrl("a")])
        XCTAssertEqual(keys("\u{04}"), [.ctrl("d")])
        XCTAssertEqual(keys("\u{1A}"), [.ctrl("z")])
    }

    func testLoneEscapeIsHeldUntilFlushed() {
        var parser = KeyParser()
        XCTAssertEqual(parser.feed([0x1B]), [])
        XCTAssertTrue(parser.hasPendingEscape)
        XCTAssertEqual(parser.flushPendingEscape(), [.escape])
        XCTAssertFalse(parser.hasPendingEscape)
    }

    func testEscapeThenArrowAcrossFeedsIsNotSplit() {
        var parser = KeyParser()
        XCTAssertEqual(parser.feed([0x1B]), [])
        XCTAssertEqual(parser.feed([0x5B, 0x41]), [.up])
    }

    func testBracketedPasteAcrossFeedsWithCRLF() {
        var parser = KeyParser()
        XCTAssertEqual(parser.feed(Array("\u{1B}[200~hi\r".utf8)), [])
        XCTAssertEqual(parser.feed(Array("\nthere".utf8)), [])
        XCTAssertEqual(parser.feed(Array("\u{1B}[201~".utf8)), [.paste("hi\nthere")])
    }

    func testPasteEndMarkerSplitAcrossFeeds() {
        var parser = KeyParser()
        XCTAssertEqual(parser.feed(Array("\u{1B}[200~one".utf8)), [])
        XCTAssertEqual(parser.feed(Array("\u{1B}[20".utf8)), [])
        XCTAssertEqual(parser.feed(Array("1~".utf8)), [.paste("one")])
        XCTAssertEqual(parser.feed(Array("x".utf8)), [.char("x")])
    }

    func testPasteKeepsEscapeAndKeysInsideAsText() {
        let out = keys("\u{1B}[200~a\u{03}b\u{1B}[201~")
        XCTAssertEqual(out, [.paste("a\u{03}b")])
    }

    func testCRLFNormalisation() {
        XCTAssertEqual(KeyParser.normalizeNewlines("a\r\nb\rc\nd"), "a\nb\nc\nd")
    }
}
