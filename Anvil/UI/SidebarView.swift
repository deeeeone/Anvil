import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed = Set<UUID>()
    @State private var query = ""
    @State private var archivedOpen = false
    /// The section whose name is being edited in place (a new section starts this way).
    @State private var renamingSection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Traffic lights sit on the left of this row.
            HStack {
                Spacer()
                IconButton(symbol: "sidebar.left", help: "Hide sidebar (⌥⌘S)") { app.showSidebar = false }
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.topBar)

            VStack(alignment: .leading, spacing: 4) {
                ProjectSwitcher()
                Button { app.newSession(); if app.sidebarFloating { app.showSidebar = false } } label: {
                    HoverRow {
                        HStack(spacing: 9) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white).frame(width: 20, height: 20)
                                .background(Theme.accent, in: Circle())
                            Text("New session").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text("⌘N").font(.system(size: 11)).foregroundStyle(Theme.text3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { Button("New Session in a Git Worktree") { app.newWorktreeSession() } }
                Button { app.newWorktreeSession(); if app.sidebarFloating { app.showSidebar = false } } label: {
                    HoverRow {
                        HStack(spacing: 9) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text2).frame(width: 20, height: 20)
                            Text("New worktree session").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                            Spacer()
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Run a session on its own branch in its own folder; merge it back when you're happy")
                if app.sessions.contains(where: { $0.workdir != nil && !$0.worktreeRemoved }) {
                    Button { app.showWorktreeCleanup = true } label: {
                        HoverRow {
                            HStack(spacing: 9) {
                                Image(systemName: "trash.slash").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.text2).frame(width: 20, height: 20)
                                Text("Clean up worktrees…").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                                Spacer()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Remove merged worktrees and their branches")
                }
            }
            .padding(.horizontal, 8)

            if !app.queue.isEmpty { QueueSection() }

            SidebarSearch(text: $query)
                .padding(.horizontal, 10).padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 1) {
                    organized
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            Hairline()
            SettingsLink {
                HoverRow {
                    HStack(spacing: 9) {
                        Image(systemName: "gearshape").foregroundStyle(Theme.text2)
                        Text("Settings").font(.system(size: 13)).foregroundStyle(Theme.text2)
                        Spacer()
                        if !AppSettings.shared.ready(model: app.current?.model ?? AppSettings.shared.model) { Circle().fill(Theme.amber).frame(width: 7, height: 7).help("No API key yet") }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    /// Pinned, then your sections, then Recents, then Archived.
    @ViewBuilder private var organized: some View {
        let layout = app.organizedRows(query: query, collapsed: collapsed)
        if !layout.pinned.isEmpty {
            GroupTitle(text: "Pinned")
            rows(layout.pinned)
        }
        ForEach(layout.sections) { group in
            SectionHeader(section: group.section, count: group.rows.count, renaming: $renamingSection)
            if !group.section.collapsed { rows(group.rows) }
        }
        GroupTitle(text: "Recents")
        rows(layout.recents)
        if !layout.archived.isEmpty {
            Button { organise(reduceMotion) { archivedOpen.toggle() } } label: {
                HoverRow {
                    HStack(spacing: 6) {
                        Image(systemName: archivedOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3).frame(width: 12)
                        Text("Archived").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                        Spacer(minLength: 4)
                        Text("\(layout.archived.count)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            if archivedOpen { rows(layout.archived) }
        }
    }

    private func rows(_ rows: [SessionTree.Row]) -> some View {
        ForEach(rows) { row in
            SessionRow(summary: row.summary, depth: row.depth, childCount: row.childCount,
                       collapsed: collapsed.contains(row.id), reduceMotion: reduceMotion,
                       toggle: {
                           organise(reduceMotion) {
                               if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                           }
                       },
                       beginSectionRename: { renamingSection = $0 })
        }
    }
}

/// Runs an organise change, sliding rows between groups unless Reduce Motion is on.
func organise(_ reduceMotion: Bool, _ change: () -> Void) {
    if reduceMotion { change() } else { withAnimation(.snappy(duration: 0.22)) { change() } }
}

/// The search field above the session list.
struct SidebarSearch: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            TextField("Search sessions", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .card(9, fill: Theme.surface)
    }
}

/// The plain heading over a group that isn't a user section.
struct GroupTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
    }
}

/// A user section's heading: click to fold it, right-click to rename or delete it.
struct SectionHeader: View {
    @Environment(AppState.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let section: MetaSection
    let count: Int
    @Binding var renaming: UUID?
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isRenaming: Bool { renaming == section.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: section.collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3).frame(width: 12)
            if isRenaming {
                TextField("Section name", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { app.renameSection(section.id, to: draft); renaming = nil }
                    .onExitCommand { renaming = nil }
                    .onAppear { focused = true }
            } else {
                Text(section.name)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
            }
        }
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { organise(reduceMotion) { app.toggleSection(section.id) } } }
        .contextMenu {
            Button("Rename") { draft = section.name; renaming = section.id }
            Button("Delete", role: .destructive) { organise(reduceMotion) { app.deleteSection(section.id) } }
        }
        .onChange(of: renaming) { _, now in if now == section.id { draft = section.name } }
    }
}

struct ProjectSwitcher: View {
    @Environment(AppState.self) private var app
    var body: some View {
        Menu {
            ForEach(RecentProjects.list(), id: \.path) { u in
                Button(u.lastPathComponent) { app.open(u) }
            }
            Divider()
            Button("Open Folder…") { app.chooseProject() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.project?.lastPathComponent ?? "Open a folder").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let p = app.project {
                        Text(Paths.display(p.deletingLastPathComponent(), root: nil)).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .card(11, fill: Theme.surface)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

struct SessionRow: View {
    @Environment(AppState.self) private var app
    let summary: SessionSummary
    var depth = 0
    var childCount = 0
    var collapsed = false
    var reduceMotion = false
    var toggle: () -> Void = {}
    /// Starts the inline name editor of a section this row just created.
    var beginSectionRename: (UUID) -> Void = { _ in }
    @State private var confirmDelete = false
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @State private var nesting = false
    @FocusState private var nameFocused: Bool

    private var selected: Bool { app.current?.session.id == summary.id }
    private var activity: SessionActivity? { app.activity[summary.id] }
    private var isPinned: Bool { app.meta.pinned.contains(summary.id) }
    private var isUnread: Bool { app.meta.unread.contains(summary.id) }
    private var isArchived: Bool { app.meta.archived.contains(summary.id) }

    /// How a sub-session is doing (nil for an ordinary session).
    private var subState: SubSession.State? { app.subSessions.first { $0.id == summary.id }?.state }

    var body: some View {
        HStack(spacing: 0) {
            if childCount > 0 {
                Button(action: toggle) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.text3).frame(width: 16, height: 24)
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Show \(childCount) sub-session\(childCount == 1 ? "" : "s")" : "Hide sub-sessions")
                .accessibilityLabel(collapsed ? "Expand sub-sessions" : "Collapse sub-sessions")
            } else if depth > 0 {
                Color.clear.frame(width: 16, height: 24)
            }
            if renaming { nameField } else { rowButton }
        }
        .padding(.leading, CGFloat(depth) * 14)
        .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
    }

    private var rowButton: some View {
        Button {
            app.select(summary.id)
            if app.sidebarFloating { app.showSidebar = false }
        } label: {
            HoverRow(selected: selected) {
                HStack(spacing: 8) {
                    if let st = subState { subIcon(st) }
                    else if summary.branch != nil { Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(summary.worktreeRemoved ? Theme.text3 : Theme.accent).help(summary.branch ?? "") }
                    Text(summary.title).font(.system(size: 13)).foregroundStyle(selected ? Theme.text : Theme.text2).lineLimit(1)
                        .strikethrough(summary.worktreeRemoved, color: Theme.text3)
                    if isUnread { Circle().fill(Theme.accent).frame(width: 6, height: 6).help("Unread") }
                    Spacer(minLength: 4)
                    if isPinned && hovering { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.text3) }
                    indicator
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .popover(isPresented: $nesting, arrowEdge: .trailing) { NestPicker(id: summary.id, dismiss: { nesting = false }) }
        .confirmationDialog("Delete \u{201C}\(summary.title)\u{201D}?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { app.delete(summary.id) }
        } message: {
            Text("The conversation goes to the Trash, so you can still get it back from there. Files the agent changed are not touched.")
        }
    }

    /// Running, waiting on the owner, or the child count or age.
    @ViewBuilder private var indicator: some View {
        if activity == .running { Spinner().scaleEffect(0.8) }
        else if activity == .needsYou { Circle().fill(Theme.amber).frame(width: 7, height: 7).help("Needs you") }
        else if childCount > 0 && collapsed { Text("\(childCount)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3) }
        else { Text(Self.age(summary.updated)).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1) }
    }

    private var nameField: some View {
        HoverRow(selected: true) {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.text)
                .focused($nameFocused)
                .onSubmit { app.rename(summary.id, to: draft); renaming = false }
                .onExitCommand { renaming = false }
        }
        .onAppear { nameFocused = true }
    }

    /// The row's menu, in Claude's order.
    @ViewBuilder private var menu: some View {
        Button("Open in Split View") { app.openInSplit(summary.id) }
            .disabled(app.current?.session.id == summary.id && !app.panes.isSplit)
        Divider()
        Button(isPinned ? "Unpin" : "Pin") { organise(reduceMotion) { app.togglePin(summary.id) } }
        Button(isUnread ? "Mark as Read" : "Mark as Unread") { app.setUnread(summary.id, !isUnread) }
        Button("Rename") { draft = summary.title; renaming = true }
        Button("Fork Session") { app.fork(summary.id, at: nil) }
        Menu("Move to Section") {
            ForEach(app.meta.sections) { sec in Button(sec.name) { move(to: sec.id) } }
            Button("New Section…") {
                let sid = app.createSection(name: "New Section")
                organise(reduceMotion) { app.move(summary.id, toSection: sid) }
                beginSectionRename(sid)
            }
            Button("Recents") { move(to: nil) }
        }
        Button("Nest Under…") { nesting = true }
        Divider()
        if isArchived { Button("Unarchive") { organise(reduceMotion) { app.unarchive(summary.id) } } }
        else { Button("Archive") { organise(reduceMotion) { app.archive(summary.id) } } }
        if summary.workdir != nil && !summary.worktreeRemoved {
            Button("Clean Up Worktrees…") { app.showWorktreeCleanup = true }
        }
        Divider()
        Button("Delete Session…", role: .destructive) { confirmDelete = true }
    }

    private func move(to section: UUID?) {
        organise(reduceMotion) { app.move(summary.id, toSection: section) }
    }

    @ViewBuilder private func subIcon(_ st: SubSession.State) -> some View {
        Group {
            switch st {
            case .waiting: Image(systemName: "clock").foregroundStyle(Theme.text3)
            case .running: Image(systemName: "arrow.turn.down.right").foregroundStyle(Theme.accent)
            case .finished: Image(systemName: "checkmark.circle").foregroundStyle(Theme.green)
            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.red)
            case .merged: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
            }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .help("Sub-session: \(st.rawValue)")
    }

    /// "now", "5m", "3h", "2d", then a date.
    static func age(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        if s < 7 * 86400 { return "\(Int(s / 86400))d" }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }
}


/// Pick the session this one is shown under in the sidebar (a quick search, like a menu).
struct NestPicker: View {
    @Environment(AppState.self) private var app
    let id: UUID
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search sessions", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    pick(nil, "Don't Nest")
                    ForEach(candidates) { s in pick(s.id, s.title) }
                }
            }
            .frame(height: 240)
        }
        .padding(10).frame(width: 260)
    }

    private func pick(_ parent: UUID?, _ label: String) -> some View {
        Button { app.nest(id, under: parent); dismiss() } label: {
            HoverRow { Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1) }
        }
        .buttonStyle(.plain)
    }

    /// Other sessions, minus any that would put this one in a loop.
    private var candidates: [SessionSummary] {
        let parents = app.nestingParents
        return app.sessions.filter { s in
            s.id != id && (query.isEmpty || s.title.localizedCaseInsensitiveContains(query))
                && !SessionMeta.wouldCycle(child: id, parent: s.id, parents: parents)
        }
    }
}

struct QueueSection: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Queue").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                Spacer()
                if app.queue.contains(where: { [.done, .failed, .cancelled].contains($0.state) }) {
                    Button("Clear done") { app.clearFinishedQueue() }.buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 6)
            ForEach(app.queue) { t in
                Button { if let id = t.sessionID { app.select(id) } } label: {
                    HoverRow(selected: t.sessionID != nil && app.current?.session.id == t.sessionID) {
                        HStack(spacing: 8) {
                            Group {
                                switch t.state {
                                case .queued: Image(systemName: "clock").foregroundStyle(Theme.text3)
                                case .running: Spinner().scaleEffect(0.75)
                                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                                case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.red)
                                case .cancelled: Image(systemName: "minus.circle").foregroundStyle(Theme.text3)
                                }
                            }
                            .font(.system(size: 11)).frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.prompt).font(.system(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                                if let b = t.branch, t.state == .done { Text(b).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(1) }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(t.summary ?? t.prompt)
                .contextMenu {
                    Button(t.state == .queued || t.state == .running ? "Cancel" : "Remove", role: .destructive) { app.cancelQueued(t.id) }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}
