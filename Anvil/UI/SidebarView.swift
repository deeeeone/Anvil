import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var collapsed = Set<UUID>()

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

            Text("Recents")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(SessionTree.rows(app.sessions, collapsed: collapsed)) { row in
                        SessionRow(summary: row.summary, selected: app.current?.session.id == row.id,
                                   running: app.current?.session.id == row.id && (app.current?.running ?? false),
                                   depth: row.depth, childCount: row.childCount, collapsed: collapsed.contains(row.id)) {
                            if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
                        }
                    }
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
    let selected: Bool
    let running: Bool
    var depth = 0
    var childCount = 0
    var collapsed = false
    var toggle: () -> Void = {}
    @State private var confirmDelete = false

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
            rowButton
        }
        .padding(.leading, CGFloat(depth) * 14)
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
                    Spacer(minLength: 4)
                    if running { Spinner().scaleEffect(0.8) }
                    else if childCount > 0 && collapsed { Text("\(childCount)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3) }
                    else { Text(Self.age(summary.updated)).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1) }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Fork Session") { app.fork(summary.id, at: nil) }
            if summary.workdir != nil && !summary.worktreeRemoved {
                Button("Clean Up Worktrees…") { app.showWorktreeCleanup = true }
            }
            Divider()
            Button("Delete Session…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete \u{201C}\(summary.title)\u{201D}?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { app.delete(summary.id) }
        } message: {
            Text("The conversation goes to the Trash, so you can still get it back from there. Files the agent changed are not touched.")
        }
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
