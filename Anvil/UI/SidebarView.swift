import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app

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
            }
            .padding(.horizontal, 8)

            if !app.queue.isEmpty { QueueSection() }

            Text("Recents")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3)
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(app.sessions) { s in
                        SessionRow(summary: s, selected: app.current?.session.id == s.id,
                                   running: app.current?.session.id == s.id && (app.current?.running ?? false))
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
                        if !AppSettings.shared.ready(Providers.provider(for: app.current?.model ?? AppSettings.shared.model)) { Circle().fill(Theme.amber).frame(width: 7, height: 7).help("No API key yet") }
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

    var body: some View {
        Button {
            app.select(summary.id)
            if app.sidebarFloating { app.showSidebar = false }
        } label: {
            HoverRow(selected: selected) {
                HStack(spacing: 8) {
                    if summary.branch != nil { Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent).help(summary.branch ?? "") }
                    Text(summary.title).font(.system(size: 13)).foregroundStyle(selected ? Theme.text : Theme.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    if running { Spinner().scaleEffect(0.8) }
                    else { Text(Self.age(summary.updated)).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(1) }
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Delete Session", role: .destructive) { app.delete(summary.id) } }
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
