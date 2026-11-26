import XCTest
@testable import Anvil

final class SplitViewTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testOpenSplitsBesideFocusedAndFocusesNew() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)
        XCTAssertTrue(p.isSplit)
        XCTAssertEqual(p.left, a)
        XCTAssertEqual(p.right, b)
        XCTAssertEqual(p.focused, b)
        XCTAssertEqual(p.other, a)
    }

    func testOpeningASessionAlreadyShownFocusesItWithoutMoving() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)
        p.open(a)
        XCTAssertEqual(p.left, a)
        XCTAssertEqual(p.right, b)
        XCTAssertEqual(p.focused, a)
    }

    func testOpenWhileSplitReplacesTheUnfocusedPane() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)          // focus b (right)
        p.open(c)          // the unfocused pane (left, a) gives way; b stays
        XCTAssertEqual(p.left, c)
        XCTAssertEqual(p.right, b)
        XCTAssertEqual(p.focused, c)
    }

    func testFocusKeepsLayoutPositions() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)
        p.focus(a)
        XCTAssertEqual(p.left, a)
        XCTAssertEqual(p.right, b)
        XCTAssertEqual(p.focused, a)
        p.focus(.right)
        XCTAssertEqual(p.focused, b)
        p.focus(c)         // not shown: ignored
        XCTAssertEqual(p.focused, b)
    }

    func testCloseSplitKeepsFocusedSession() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)
        p.focus(a)
        p.closeSplit()
        XCTAssertFalse(p.isSplit)
        XCTAssertEqual(p.left, a)
        XCTAssertNil(p.right)
        XCTAssertEqual(p.focused, a)
    }

    func testClosingTheUnfocusedPaneKeepsFocus() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)          // focus b
        p.close(a)
        XCTAssertFalse(p.isSplit)
        XCTAssertEqual(p.left, b)
        XCTAssertEqual(p.focused, b)
    }

    func testClosingTheFocusedPaneFocusesTheOther() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)          // focus b
        p.close(b)
        XCTAssertEqual(p.left, a)
        XCTAssertEqual(p.focused, a)
        XCTAssertFalse(p.isSplit)
    }

    func testRemovingADeletedSessionClosesItsPane() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)
        p.remove(b)
        XCTAssertFalse(p.isSplit)
        XCTAssertEqual(p.focused, a)
        p.remove(a)
        XCTAssertNil(p.focused)
        XCTAssertNil(p.left)
    }

    func testRemovingAnUnknownSessionChangesNothing() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)
        let before = p
        p.remove(c)
        XCTAssertEqual(p, before)
    }

    func testSelectReplacesTheFocusedPane() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)          // focus b
        p.replaceFocused(c)
        XCTAssertEqual(p.left, a)
        XCTAssertEqual(p.right, c)
        XCTAssertEqual(p.focused, c)
    }

    func testSelectingASessionAlreadyShownFocusesIt() {
        var p = PaneLayout()
        p.replaceFocused(a)
        p.open(b)          // focus b
        p.replaceFocused(a)
        XCTAssertEqual(p.left, a)
        XCTAssertEqual(p.right, b)
        XCTAssertEqual(p.focused, a)
    }

    func testRatioKeepsEachPaneAtLeastMinimumWidth() {
        let available: CGFloat = 1000
        XCTAssertEqual(PaneSizing.ratio(0.5, available: available), 0.5, accuracy: 0.0001)
        let lo = PaneSizing.ratio(0, available: available)
        XCTAssertEqual(lo * available, PaneSizing.minPane, accuracy: 0.5)
        let hi = PaneSizing.ratio(1, available: available)
        XCTAssertEqual((1 - hi) * available, PaneSizing.minPane, accuracy: 0.5)
    }
}
