import Foundation
import CoreGraphics

/// Which side of the split view a pane sits on.
enum PaneSide { case left, right }

/// Which sessions are in the split view's two panes, and which pane has focus. Pure values: AppState holds the controllers.
/// `left` is always the first pane; `right` is set only while split. In a single pane, that pane is `left` and `focused`.
struct PaneLayout: Equatable {
    private(set) var left: UUID?
    private(set) var right: UUID?
    private(set) var focused: UUID?

    var isSplit: Bool { left != nil && right != nil }
    var ids: [UUID] { [left, right].compactMap { $0 } }
    /// The pane that isn't focused, while split.
    var other: UUID? {
        guard isSplit else { return nil }
        return focused == left ? right : left
    }
    func contains(_ id: UUID) -> Bool { left == id || right == id }

    /// Shows `id` next to the focused session: the unfocused pane takes it and focus moves there.
    /// A session already shown is just focused.
    mutating func open(_ id: UUID) {
        if contains(id) { focused = id; return }
        guard let f = focused else { left = id; right = nil; focused = id; return }
        if left == f { right = id } else { left = id }
        focused = id
    }

    /// Puts `id` in the focused pane (a new or picked session replaces what was there). A session already shown is focused instead.
    mutating func replaceFocused(_ id: UUID) {
        if contains(id) { focused = id; return }
        guard let f = focused else { left = id; right = nil; focused = id; return }
        if left == f { left = id } else { right = id }
        focused = id
    }

    /// Focuses a session that is shown in a pane. Other ids are ignored.
    mutating func focus(_ id: UUID) {
        if contains(id) { focused = id }
    }

    /// Focuses the pane on `side`, if there is one.
    mutating func focus(_ side: PaneSide) {
        switch side {
        case .left: if let left { focused = left }
        case .right: if let right { focused = right }
        }
    }

    /// Ends the split. The focused session stays, in the single pane.
    mutating func closeSplit() {
        guard isSplit, let f = focused else { return }
        left = f
        right = nil
    }

    /// Closes one pane of a split. The other session stays; focus stays with the session that remains focused.
    mutating func close(_ id: UUID) {
        guard isSplit, contains(id) else { return }
        let keep = left == id ? right : left
        left = keep
        right = nil
        if focused == id { focused = keep }
    }

    /// A session was deleted or is gone: take it out of the panes.
    mutating func remove(_ id: UUID) {
        guard contains(id) else { return }
        if isSplit { close(id) } else { left = nil; focused = nil }
    }
}

/// Sizes of the split view, in points.
enum PaneSizing {
    /// The least width either pane gets.
    static let minPane: CGFloat = 380
    /// The main area is at least this wide before two panes are shown side by side (narrower: the focused pane only).
    static let minSplitWidth: CGFloat = 780

    /// The left pane's share of `available` (the width both panes share, without the divider), kept so each pane is at least `minPane`.
    static func ratio(_ r: CGFloat, available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0.5 }
        let lo = min(0.5, minPane / available)
        return min(max(r, lo), 1 - lo)
    }
}
