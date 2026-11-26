import SwiftUI

/// One row of the command palette: a session to go to, an action, a model, a mode or a slash command.
nonisolated struct PaletteItem: Identifiable, Sendable {
    let id: String
    let title: String
    var detail = ""
    let symbol: String
    var shortcut: String?
    /// Which kind of item this is ("Go to", "Actions", "Model"...).
    var group = ""
    let run: @MainActor @Sendable () -> Void
}

/// Fuzzy matching for the palette, as pure functions so they can be tested.
nonisolated enum PaletteMatch {
    /// How well `query` matches `text`, or nil when the query's characters don't appear in order (case-insensitive).
    /// A prefix ranks highest, then matches at word starts, then runs of consecutive characters.
    static func score(_ query: String, _ text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var score = t.starts(with: q) ? 200 : 0
        var from = 0
        var prev = -1
        for qc in q {
            guard let p = t[from...].firstIndex(of: qc) else { return nil }
            score += 10
            if p == 0 || !(t[p - 1].isLetter || t[p - 1].isNumber) { score += 20 }
            if p == prev + 1 { score += 15 }
            score -= min(p - prev - 1, 5)
            prev = p
            from = p + 1
        }
        return score
    }

    /// The items whose titles match `query`, best first (ties keep their order). An empty query keeps them all.
    static func rank(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.enumerated()
            .compactMap { i, item in score(q, item.title).map { (score: $0, index: i, item: item) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.item)
    }
}

/// Session order for quick switching (⌃Tab): most recently used first, then the rest in sidebar order.
nonisolated enum QuickSwitch {
    /// `id` moved to the front of `recent`, without duplicates, capped at `cap` entries.
    static func touched(_ recent: [UUID], _ id: UUID, cap: Int = 30) -> [UUID] {
        Array(([id] + recent.filter { $0 != id }).prefix(cap))
    }

    /// The order to cycle through: recent sessions that still exist, then every other session in `all` order.
    static func ordered(recent: [UUID], all: [UUID]) -> [UUID] {
        let live = Set(all)
        var seen = Set<UUID>()
        var out: [UUID] = []
        for id in recent + all where live.contains(id) && seen.insert(id).inserted { out.append(id) }
        return out
    }

    /// The entry after (or before, when `backward`) `current` in `order`, wrapping around. Nil when there is nothing else.
    static func cycle(_ order: [UUID], from current: UUID?, backward: Bool) -> UUID? {
        let n = order.count
        guard n > 1 else { return nil }
        guard let i = current.flatMap({ order.firstIndex(of: $0) }) else { return backward ? order[n - 1] : order[0] }
        return order[backward ? (i - 1 + n) % n : (i + 1) % n]
    }
}

/// Palette and quick-switch state shared by the menu commands and the overlay.
@Observable
final class PaletteState {
    static let shared = PaletteState()
    var isOpen = false
    /// The items for the open palette (built when it opens, so the slash command scan runs once).
    private(set) var items: [PaletteItem] = []
    @ObservationIgnored var recent: [UUID] = []
    /// The session ⌃Tab just switched to: its selection doesn't reorder the recent list.
    @ObservationIgnored var cyclingTo: UUID?
    @ObservationIgnored var openSettings: (() -> Void)?

    func show(_ app: AppState) {
        items = CommandPalette.items(app: app)
        isOpen = true
    }

    func toggle(_ app: AppState) {
        if isOpen { isOpen = false } else { show(app) }
    }

    /// ⌃Tab / ⌃⇧Tab: the next or previous session in quick-switch order.
    func switchRecent(_ app: AppState, backward: Bool) {
        let order = QuickSwitch.ordered(recent: recent, all: app.sessions.map(\.id))
        guard let target = QuickSwitch.cycle(order, from: app.current?.session.id, backward: backward) else { return }
        cyclingTo = target
        app.select(target)
    }
}

/// The ⌘K palette. Items come from `items(app:)`; features add more with `extraItems`.
enum CommandPalette {
    /// Extra items appended after the built-in ones (for example pin, split or archive actions).
    static var extraItems: [(AppState) -> [PaletteItem]] = []

    static func items(app: AppState) -> [PaletteItem] {
        var out: [PaletteItem] = []
        let current = app.current

        for s in app.sessions.sorted(by: { $0.updated > $1.updated }) {
            let running = app.controller(for: s.id)?.running == true
            out.append(PaletteItem(id: "session.\(s.id)", title: s.title, detail: running ? "running" : "",
                                   symbol: "bubble.left", shortcut: nil, group: "Go to") { app.select(s.id) })
        }

        out.append(PaletteItem(id: "new", title: "New session", symbol: "square.and.pencil", shortcut: "⌘N", group: "Actions") { app.newSession() })
        out.append(PaletteItem(id: "new.worktree", title: "New worktree session", detail: "its own branch and folder",
                               symbol: "arrow.triangle.branch", shortcut: nil, group: "Actions") { app.newWorktreeSession() })
        out.append(PaletteItem(id: "open", title: "Open folder…", symbol: "folder", shortcut: "⌘O", group: "Actions") { app.chooseProject() })
        if let current {
            out.append(PaletteItem(id: "fork", title: "Fork current session", symbol: "arrow.triangle.2.circlepath", shortcut: nil, group: "Actions") {
                app.fork(current.session.id, at: nil)
            })
            if current.running {
                out.append(PaletteItem(id: "stop", title: "Stop the agent", symbol: "stop.circle", shortcut: "⌘.", group: "Actions") { app.current?.stop() })
            }
        }
        out.append(PaletteItem(id: "sidebar", title: "Toggle sidebar", symbol: "sidebar.left", shortcut: "⌥⌘S", group: "Actions") { app.showSidebar.toggle() })
        out.append(PaletteItem(id: "inspector", title: "Toggle inspector", symbol: "sidebar.right", shortcut: "⌥⌘I", group: "Actions") { app.showInspector.toggle() })
        for tab in InspectorTab.allCases {
            out.append(PaletteItem(id: "tab.\(tab.rawValue)", title: "Show \(tab.rawValue)", symbol: tab.symbol, shortcut: nil, group: "Actions") {
                app.inspectorTab = tab
                app.inspectorDismissed = false
                app.showInspector = true
            })
        }
        out.append(PaletteItem(id: "settings", title: "Open Settings", symbol: "gearshape", shortcut: "⌘,", group: "Actions") {
            PaletteState.shared.openSettings?()
        })

        if let current {
            var listedModels = Set<String>()
            for choice in ModelCatalog.shared.choices where AppSettings.shared.ready(model: choice.id) {
                guard listedModels.insert(choice.id).inserted else { continue }
                let isCurrent = choice.id == current.model
                out.append(PaletteItem(id: "model.\(choice.id)", title: "Model: \(choice.id)",
                                       detail: [isCurrent ? "current" : "", choice.detail].filter { !$0.isEmpty }.joined(separator: " · "),
                                       symbol: "cpu", shortcut: nil, group: "Model") { app.current?.model = choice.id })
            }
            for mode in PermissionMode.allCases {
                out.append(PaletteItem(id: "mode.\(mode.rawValue)", title: "Mode: \(mode.label)",
                                       detail: mode == current.mode ? "current" : "", symbol: mode.symbol, shortcut: nil, group: "Mode") {
                    app.current?.mode = mode
                })
            }
            for cmd in SlashCommands.all(project: app.project) {
                // Commands that take arguments go into the composer; the rest run now, as typing them would.
                let takesArgs = cmd.summary.contains(":") || cmd.summary.contains("<") || cmd.name == "queue"
                    || (cmd.body?.contains("$ARGUMENTS") ?? false)
                out.append(PaletteItem(id: "slash.\(cmd.name)", title: "/\(cmd.name)", detail: cmd.summary,
                                       symbol: "chevron.left.forwardslash.chevron.right", shortcut: nil, group: "Commands") {
                    guard let c = app.current else { return }
                    if takesArgs { c.draft = "/\(cmd.name) " } else { c.send("/\(cmd.name)") }
                })
            }
        }

        // Organising the current session, and the split.
        if let id = app.current?.session.id {
            let pinned = app.meta.pinned.contains(id)
            out.append(PaletteItem(id: "org.pin", title: pinned ? "Unpin This Session" : "Pin This Session", symbol: pinned ? "pin.slash" : "pin", group: "Actions") { withAnimation(.snappy(duration: 0.22)) { app.togglePin(id) } })
            out.append(PaletteItem(id: "org.archive", title: "Archive This Session", symbol: "archivebox", group: "Actions") { withAnimation(.snappy(duration: 0.22)) { app.archive(id) } })
        }
        out.append(PaletteItem(id: "split.toggle", title: app.panes.isSplit ? "Close Split View" : "Open Split View", symbol: "rectangle.split.2x1", shortcut: "⌘\\", group: "Actions") {
            withAnimation(.snappy(duration: 0.22)) { app.toggleSplit() }
        })
        for s in app.sessions.prefix(30) where s.id != app.current?.session.id && !app.panes.contains(s.id) {
            out.append(PaletteItem(id: "split.\(s.id)", title: "Open in Split: \(s.title)", symbol: "rectangle.righthalf.inset.filled", group: "Split") {
                withAnimation(.snappy(duration: 0.22)) { app.openInSplit(s.id) }
            })
        }

        for extra in extraItems { out += extra(app) }
        return out
    }
}

/// Mounted once over the whole window; draws nothing (and takes no clicks) while the palette is closed.
struct CommandPaletteOverlay: View {
    @Environment(AppState.self) private var app
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let state = PaletteState.shared

    var body: some View {
        ZStack(alignment: .top) {
            if state.isOpen {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { state.isOpen = false }
                    .transition(.opacity)
                CommandPalettePanel(items: state.items) { state.isOpen = false }
                    .padding(.top, 96)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: state.isOpen)
        .onAppear {
            state.openSettings = { openSettings() }
            if let id = app.current?.session.id { state.recent = QuickSwitch.touched(state.recent, id) }
        }
        .onChange(of: app.current?.session.id) { old, id in
            guard let id else { return }
            if state.cyclingTo == id {
                // A ⌃Tab switch keeps the cycling order; the session it left is recorded once you leave it another way.
                state.cyclingTo = nil
                return
            }
            if let old { state.recent = QuickSwitch.touched(state.recent, old) }
            state.recent = QuickSwitch.touched(state.recent, id)
        }
    }
}

/// The palette itself. Its query and selection reset each time it opens (it is recreated then).
private struct CommandPalettePanel: View {
    let items: [PaletteItem]
    let close: () -> Void
    @State private var query = ""
    @State private var selection = 0
    /// Mouse hover only moves the selection after the mouse really moved, so scrolling with the arrow keys doesn't fight it.
    @State private var hoverEnabled = true
    @State private var lastPointer: CGPoint?
    @FocusState private var fieldFocused: Bool
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let rowHeight: CGFloat = 36
    private let maxRows = 9

    private var rows: [PaletteItem] { PaletteMatch.rank(items, query: query) }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                TextField("Search sessions and commands", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { runSelected(rows) }
                    .onKeyPress(.upArrow) { move(-1, count: rows.count); return .handled }
                    .onKeyPress(.downArrow) { move(1, count: rows.count); return .handled }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Hairline()
            if rows.isEmpty {
                Text("No matches")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: rowHeight * 2)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, item in
                                row(item, index: i)
                                    .id(item.id)
                            }
                        }
                        .padding(6)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: selection)
                    }
                    .frame(height: CGFloat(min(rows.count, maxRows)) * rowHeight + 12)
                    .onChange(of: selection) { _, s in
                        if rows.indices.contains(s) { proxy.scrollTo(rows[s].id) }
                    }
                    .onContinuousHover(coordinateSpace: .global) { phase in
                        guard case .active(let p) = phase else { return }
                        if p != lastPointer { hoverEnabled = true; lastPointer = p }
                    }
                }
            }
        }
        .frame(width: 560)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
        .onKeyPress(.escape) { close(); return .handled }
        .onExitCommand(perform: close)
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func row(_ item: PaletteItem, index i: Int) -> some View {
        let selected = i == selection
        return Button {
            close()
            DispatchQueue.main.async { item.run() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 12)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let shortcut = item.shortcut {
                    Text(shortcut)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surface2)
                        .matchedGeometryEffect(id: "highlight", in: highlight)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 && hoverEnabled { selection = i } }
    }

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        hoverEnabled = false
        selection = (selection + step + count) % count
    }

    private func runSelected(_ rows: [PaletteItem]) {
        guard rows.indices.contains(selection) else { return }
        let item = rows[selection]
        close()
        DispatchQueue.main.async { item.run() }
    }
}
