import XCTest
@testable import AnvilCore

/// Collects what LiveScreen writes.
private final class Sink {
    var chunks: [String] = []
    var all: String { chunks.joined() }
    func take() -> String {
        let s = all
        chunks = []
        return s
    }
}

final class TUILiveScreenTests: XCTestCase {
    private func makeScreen(interactive: Bool = true, cols: Int = 40, rows: Int = 20) -> (LiveScreen, Sink) {
        let sink = Sink()
        let screen = LiveScreen(
            interactive: interactive,
            write: { sink.chunks.append($0) },
            size: { (cols: cols, rows: rows) }
        )
        return (screen, sink)
    }

    @MainActor
    func testFirstFrameDrawsEveryLine() {
        let (screen, sink) = makeScreen()
        screen.setLive(["alpha", "beta"], cursor: nil)
        XCTAssertTrue(sink.all.contains("alpha"))
        XCTAssertTrue(sink.all.contains("beta"))
    }

    @MainActor
    func testSecondFrameRewritesOnlyChangedLine() {
        let (screen, sink) = makeScreen()
        screen.setLive(["UNCHANGED-ROW", "first"], cursor: nil)
        _ = sink.take()
        screen.setLive(["UNCHANGED-ROW", "second"], cursor: nil)
        let frame = sink.all
        XCTAssertTrue(frame.contains("second"))
        XCTAssertFalse(frame.contains("UNCHANGED-ROW"), "unchanged row was rewritten")
        XCTAssertFalse(frame.contains("first"))
    }

    @MainActor
    func testNeverClearsTheScreenOrGoesHome() {
        let (screen, sink) = makeScreen()
        screen.setLive(["a", "b", "c"], cursor: (row: 1, col: 0))
        screen.setLive(["a"], cursor: nil)
        screen.commit(["done"])
        screen.resized()
        screen.clearLive()
        screen.finish()
        let out = sink.all
        XCTAssertFalse(out.contains("\u{1B}[2J"))
        XCTAssertFalse(out.contains("\u{1B}[H"))
        XCTAssertFalse(out.contains("\u{1B}[?1049h"))
    }

    @MainActor
    func testFramesAreSynchronized() {
        let (screen, sink) = makeScreen()
        screen.setLive(["x"], cursor: nil)
        screen.setLive(["y"], cursor: (row: 0, col: 1))
        screen.commit(["z"])
        for chunk in sink.chunks {
            XCTAssertTrue(chunk.hasPrefix("\u{1B}[?2026h"), "frame not opened: \(chunk.debugDescription)")
            XCTAssertTrue(chunk.hasSuffix("\u{1B}[?2026l"), "frame not closed: \(chunk.debugDescription)")
        }
    }

    @MainActor
    func testCommitPrintsBeforeTheRedrawnRegion() {
        let (screen, sink) = makeScreen()
        screen.setLive(["LIVE-A"], cursor: nil)
        _ = sink.take()
        screen.commit(["COMMITTED-LINE"])
        let out = sink.all
        guard let committed = out.range(of: "COMMITTED-LINE"),
              let live = out.range(of: "LIVE-A") else {
            return XCTFail("commit output missing text: \(out.debugDescription)")
        }
        XCTAssertLessThan(committed.lowerBound, live.lowerBound)
    }

    @MainActor
    func testCommitWrapsToOneColumnLessThanWidth() {
        let (screen, sink) = makeScreen(cols: 10)
        screen.commit(["abcdefghijklmnop"])
        let out = sink.all
        XCTAssertTrue(out.contains("abcdefghi\r\n"), out.debugDescription)
        XCTAssertFalse(out.contains("abcdefghij"))
    }

    @MainActor
    func testCursorShownOnlyWhenGiven() {
        let (screen, sink) = makeScreen()
        screen.setLive(["ab"], cursor: (row: 0, col: 2))
        XCTAssertTrue(sink.all.contains("\u{1B}[?25h"))
        _ = sink.take()
        screen.setLive(["ab"], cursor: nil)
        XCTAssertTrue(sink.all.contains("\u{1B}[?25l"))
    }

    @MainActor
    func testShrinkingRegionClearsLeftovers() {
        let (screen, sink) = makeScreen()
        screen.setLive(["a", "b", "c"], cursor: nil)
        _ = sink.take()
        screen.setLive(["a"], cursor: nil)
        XCTAssertTrue(sink.all.contains("\u{1B}[J"))
        XCTAssertFalse(sink.all.contains("\u{1B}[2Kb"))
    }

    @MainActor
    func testThrottledFrameWaitsForFlush() {
        let (screen, sink) = makeScreen()
        screen.setLiveThrottled(["queued"], cursor: nil)
        XCTAssertEqual(sink.all, "")
        screen.flush()
        XCTAssertTrue(sink.all.contains("queued"))
    }

    @MainActor
    func testResizedRedrawsAtNewWidthWithoutFullClear() {
        let (screen, sink) = makeScreen(cols: 40)
        screen.setLive(["the live row"], cursor: nil)
        _ = sink.take()
        screen.resized()
        let out = sink.all
        XCTAssertTrue(out.contains("the live row"))
        XCTAssertTrue(out.contains("\u{1B}[J"))
        XCTAssertFalse(out.contains("\u{1B}[2J"))
    }

    /// A terminal size that a test can change between calls.
    private final class SizeBox {
        var cols: Int
        init(cols: Int) { self.cols = cols }
    }

    @MainActor
    func testWideningMovesUpOverHardBrokenRows() {
        // A 100-char line at 40 columns is three hard-broken rows (39 + 39 + 22). After widening to 120 they
        // still occupy three physical rows, so the redraw must move up two rows, not zero.
        let box = SizeBox(cols: 40)
        let sink = Sink()
        let screen = LiveScreen(
            interactive: true,
            write: { sink.chunks.append($0) },
            size: { (cols: box.cols, rows: 30) }
        )
        screen.setLive([String(repeating: "a", count: 100)], cursor: nil)
        _ = sink.take()
        box.cols = 120
        screen.resized()
        XCTAssertTrue(sink.all.contains("\u{1B}[2A"), sink.all.debugDescription)
    }

    @MainActor
    func testClearLiveErasesRegion() {
        let (screen, sink) = makeScreen()
        screen.setLive(["a", "b"], cursor: nil)
        _ = sink.take()
        screen.clearLive()
        XCTAssertTrue(sink.all.contains("\u{1B}[J"))
    }

    @MainActor
    func testNonInteractiveEmitsNoEscapes() {
        let (screen, sink) = makeScreen(interactive: false)
        screen.setLive(["live"], cursor: (row: 0, col: 1))
        screen.commit(["plain", Ansi.bold("styled")])
        screen.resized()
        screen.clearLive()
        screen.finish()
        XCTAssertFalse(sink.all.contains("\u{1B}"))
        XCTAssertTrue(sink.all.contains("plain\nstyled\n"))
        XCTAssertFalse(sink.all.contains("live"))
    }
}
