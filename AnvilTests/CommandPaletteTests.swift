import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class CommandPaletteTests: XCTestCase {
    private func item(_ title: String) -> PaletteItem {
        PaletteItem(id: title, title: title, symbol: "circle", run: {})
    }

    func testFuzzyMatchesInOrderOnly() {
        XCTAssertNotNil(PaletteMatch.score("nws", "New worktree session"))
        XCTAssertNotNil(PaletteMatch.score("tsb", "Toggle sidebar"))
        XCTAssertNil(PaletteMatch.score("xyz", "New worktree session"))
        XCTAssertNil(PaletteMatch.score("ts", "Stop"), "characters must appear in order")
        XCTAssertEqual(PaletteMatch.score("", "anything"), 0)
    }

    func testFuzzyIsCaseInsensitiveAndIgnoresSpaces() {
        XCTAssertNotNil(PaletteMatch.score("NEW", "new session"))
        XCTAssertNotNil(PaletteMatch.score("new s", "New session"))
    }

    func testPrefixRanksAboveWordStartAboveScattered() {
        let prefix = PaletteMatch.score("ses", "Session one")!
        let wordStart = PaletteMatch.score("ses", "Go to session list")!
        let scattered = PaletteMatch.score("ses", "Show the inspector tab with settings")!
        XCTAssertGreaterThan(prefix, wordStart)
        XCTAssertGreaterThan(wordStart, scattered)
    }

    func testRankFiltersAndKeepsOrderForTies() {
        let items = [item("Fork current session"), item("Open Settings"), item("Stop the agent"), item("Show Git")]
        XCTAssertEqual(PaletteMatch.rank(items, query: "").map(\.title), items.map(\.title))
        XCTAssertEqual(PaletteMatch.rank(items, query: "s").count, 4)
        XCTAssertEqual(PaletteMatch.rank(items, query: "open").first?.title, "Open Settings")
        XCTAssertEqual(PaletteMatch.rank(items, query: "zzz").count, 0)
        // Equal scores keep their original order.
        let pair = [PaletteItem(id: "a", title: "Alpha tab", symbol: "circle", run: {}),
                    PaletteItem(id: "b", title: "Alpha tab", symbol: "circle", run: {})]
        XCTAssertEqual(PaletteMatch.rank(pair, query: "alpha").map(\.id), ["a", "b"])
    }

    func testTouchedMovesToFrontWithoutDuplicatesAndCaps() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(QuickSwitch.touched([a, b], c), [c, a, b])
        XCTAssertEqual(QuickSwitch.touched([a, b, c], b), [b, a, c])
        XCTAssertEqual(QuickSwitch.touched([a, b], a, cap: 1), [a])
        XCTAssertEqual(QuickSwitch.touched([a, b, c], UUID(), cap: 3).count, 3)
    }

    func testOrderedDropsGoneSessionsAndAppendsTheRest() {
        let a = UUID(), b = UUID(), c = UUID(), gone = UUID()
        XCTAssertEqual(QuickSwitch.ordered(recent: [b, gone, a], all: [a, b, c]), [b, a, c])
        XCTAssertEqual(QuickSwitch.ordered(recent: [], all: [a, b]), [a, b])
    }

    func testCycleWrapsForwardAndBackward() {
        let a = UUID(), b = UUID(), c = UUID()
        let order = [a, b, c]
        XCTAssertEqual(QuickSwitch.cycle(order, from: a, backward: false), b)
        XCTAssertEqual(QuickSwitch.cycle(order, from: c, backward: false), a)
        XCTAssertEqual(QuickSwitch.cycle(order, from: a, backward: true), c)
        XCTAssertEqual(QuickSwitch.cycle(order, from: b, backward: true), a)
        // Unknown current: forward goes to the first, backward to the last.
        XCTAssertEqual(QuickSwitch.cycle(order, from: UUID(), backward: false), a)
        XCTAssertEqual(QuickSwitch.cycle(order, from: nil, backward: true), c)
    }

    func testCycleNeedsAtLeastTwoSessions() {
        let a = UUID()
        XCTAssertNil(QuickSwitch.cycle([], from: nil, backward: false))
        XCTAssertNil(QuickSwitch.cycle([a], from: a, backward: false))
    }
}
