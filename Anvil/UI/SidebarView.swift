import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    @State private var showFiles = true
    @State private var renaming: UUID?

    var body: some View {
        List(selection: Binding(get: { app.current?.session.id }, set: { if let id = $0 { app.select(id) } })) {
            Section {
                ForEach(app.sessions) { s in
                    SessionRow(summary: s, running: app.current?.session.id == s.id && (app.current?.running ?? false))
                        .tag(s.id)
                        .contextMenu {
                            Button("Delete Session", role: .destructive) { app.delete(s.id) }
                        }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    Button { app.newSession() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("New session (⌘N)")
                }
            }
            if let root = app.project {
                Section(isExpanded: $showFiles) {
                    FileTree(url: root, root: root)
                } header: {
                    Text("Files")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            Button { app.chooseProject() } label: {
                HStack {
                    Image(systemName: "folder")
                    Text(app.project?.lastPathComponent ?? "Open Folder…").fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.top, 6)
            .help(app.project?.path ?? "Open a project folder")
        }
    }
}

struct SessionRow: View {
    let summary: SessionSummary
    let running: Bool
    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).lineLimit(1)
                Text(summary.updated, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if running { ProgressView().controlSize(.mini) }
        }
    }
}

struct FileTree: View {
    @Environment(AppState.self) private var app
    let url: URL
    let root: URL

    var body: some View {
        ForEach(children, id: \.path) { child in
            if isDir(child) {
                DisclosureGroup {
                    FileTree(url: child, root: root)
                } label: {
                    Label(child.lastPathComponent, systemImage: "folder").lineLimit(1)
                }
            } else {
                Button {
                    app.previewFile = child
                    app.inspectorTab = .changes
                    app.showInspector = true
                } label: {
                    Label(child.lastPathComponent, systemImage: "doc.text").lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var children: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { !ProjectContext.skipDirs.contains($0.lastPathComponent) }
            .sorted { a, b in
                let da = isDir(a), db = isDir(b)
                return da != db ? da : a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            .prefix(300).map { $0 }
    }

    private func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
}
