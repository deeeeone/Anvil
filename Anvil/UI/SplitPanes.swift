import SwiftUI
import AppKit

private struct PaneFocusedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False in a split view's unfocused pane: its keyboard shortcuts and focus stay off.
    var anvilPaneFocused: Bool {
        get { self[PaneFocusedKey.self] }
        set { self[PaneFocusedKey.self] = newValue }
    }
}

extension View {
    /// Attaches the shortcut only while `focused` (its pane has focus), so two panes never fight over one key.
    /// Off while the command palette is open: its Return must never approve a permission or plan behind it.
    @ViewBuilder func paneShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command, when focused: Bool) -> some View {
        if focused && !PaletteState.shared.isOpen { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}

/// The conversation area: the focused session, or two sessions side by side while split.
/// Two panes need the main area to be wide enough (`app.splitFits`); narrower, only the focused pane shows.
struct PanesArea: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let paired = app.panes.isSplit && app.splitFits
            let leftID = paired ? app.panes.left : app.panes.focused
            let rightID = paired ? app.panes.right : nil
            let available = max(1, geo.size.width - 1)
            let leftWidth = (available * PaneSizing.ratio(app.paneRatio, available: available)).rounded()
            let leftFrame: CGFloat? = rightID == nil ? nil : leftWidth
            let leftFill: CGFloat? = rightID == nil ? .infinity : nil
            HStack(spacing: 0) {
                if let id = leftID, let c = app.controller(for: id) {
                    SessionPane(controller: c, showsHeader: rightID != nil)
                        .frame(width: leftFrame)
                        .frame(maxWidth: leftFill, maxHeight: .infinity)
                } else {
                    WelcomeView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let id = rightID, let c = app.controller(for: id) {
                    PaneDivider(available: available)
                        .transition(slide)
                    SessionPane(controller: c, showsHeader: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(slide)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: rightID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The new pane slides in from the trailing edge (fades only with Reduce Motion).
    private var slide: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
    }
}

/// One pane: a slim header (title, close) above the session's conversation. Clicking anywhere in it focuses it.
/// The inspector's browser is one browser shared by both sessions, so two sessions driving it can collide (no fix yet).
struct SessionPane: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let controller: SessionController
    /// Only while split: a lone pane already has the window's title bar, so a second title row would repeat it.
    var showsHeader = true

    var body: some View {
        let id = controller.session.id
        let focused = app.panes.focused == id
        VStack(spacing: 0) {
            if showsHeader { header(id: id, focused: focused) }
            ConversationView(controller: controller)
                .id(id)
                .environment(\.anvilPaneFocused, focused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { app.focus(id) })
    }

    /// Title and close button over a pane while split; the focused pane gets an accent hairline.
    @ViewBuilder private func header(id: UUID, focused: Bool) -> some View {
        HStack(spacing: 8) {
            Text(controller.session.title)
                .font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(focused ? Theme.text : Theme.text2)
            Spacer(minLength: 6)
            IconButton(symbol: "xmark", help: "Close this pane. The session keeps running.", size: 22) { app.closePane(id) }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.accent.opacity(0.7)).frame(height: 1).opacity(focused ? 1 : 0)
        }
        .help("Both sessions share the inspector's browser, so two sessions driving it at once can collide.")
        Hairline()
    }
}

/// The draggable 1pt divider between the panes (8pt hit area). Double-click resets the split to 50/50.
struct PaneDivider: View {
    @Environment(AppState.self) private var app
    /// The width both panes share (the window's main area, less the divider).
    let available: CGFloat
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle().fill(Theme.border).frame(width: 1)
            .overlay {
                Color.clear.frame(width: 8).contentShape(Rectangle())
                    .onHover { inside in
                        guard inside != hovering else { return }
                        hovering = inside
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                let start = dragStart ?? app.paneRatio
                                dragStart = start
                                app.paneRatio = PaneSizing.ratio(start + v.translation.width / available, available: available)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .simultaneousGesture(TapGesture(count: 2).onEnded { app.paneRatio = 0.5 })
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
    }
}
