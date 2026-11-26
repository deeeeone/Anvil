import SwiftUI

/// One custom layout instead of split views: it adapts to the window width.
/// - wide (≥ 1100): sidebar | conversation | inspector side by side
/// - medium: sidebar | conversation, the inspector slides over as a rounded panel
/// - narrow (< 820): conversation only, the sidebar slides over too
struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            let w = geo.size.width
            let wide = w >= 1100
            let sidebarInline = w >= 820
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if app.showSidebar && sidebarInline {
                        SidebarView().frame(width: 248)
                        Hairline(vertical: true)
                    }
                    MainColumn(leadingInset: app.showSidebar && sidebarInline ? 0 : 76)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // While split the inspector is an overlay, so the two panes keep the room.
                    if app.showInspector && wide && !app.panes.isSplit {
                        Hairline(vertical: true)
                        InspectorView().frame(width: min(max(w * 0.36, 360), 620))
                    }
                }
                if app.showInspector && (!wide || app.panes.isSplit) {
                    overlayScrim { app.showInspector = false }
                    HStack {
                        Spacer(minLength: 0)
                        InspectorView()
                            .frame(width: min(460, w - 32))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.borderStrong))
                            .shadow(color: .black.opacity(0.6), radius: 30, x: -6)
                            .padding(10)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if app.showSidebar && !sidebarInline {
                    overlayScrim { app.showSidebar = false }
                    SidebarView()
                        .frame(width: 264)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.borderStrong))
                        .shadow(color: .black.opacity(0.6), radius: 30, x: 6)
                        .padding(8)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.22), value: app.showInspector)
            .animation(.snappy(duration: 0.22), value: app.showSidebar)
            .onAppear {
                app.isWide = wide
                app.sidebarFloating = !sidebarInline
                if !sidebarInline { app.showSidebar = false }
            }
            .onChange(of: wide) { _, v in app.isWide = v }
            // Crossing the breakpoint: the sidebar follows the room available (still toggleable either way).
            .onChange(of: sidebarInline) { _, v in app.showSidebar = v; app.sidebarFloating = !v }
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $app.showModelPicker) {
            if let c = app.current { ModelPickerSheet(controller: c) }
        }
        .sheet(isPresented: $app.showWorktreeCleanup) { WorktreeCleanupView() }
        .overlay { CommandPaletteOverlay() }
    }

    func overlayScrim(_ close: @escaping () -> Void) -> some View {
        Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: close).transition(.opacity)
    }
}

struct MainColumn: View {
    @Environment(AppState.self) private var app
    /// Room for the window's traffic lights when the sidebar isn't showing.
    let leadingInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            TopBar(leadingInset: leadingInset)
            PanesArea()
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= PaneSizing.minSplitWidth } action: { app.splitFits = $0 }
    }
}

struct TopBar: View {
    @Environment(AppState.self) private var app
    let leadingInset: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            if leadingInset > 0 {
                Color.clear.frame(width: leadingInset - 10, height: 1)
                IconButton(symbol: "sidebar.left", help: "Show sidebar (⌥⌘S)") { app.showSidebar = true }
            }
            if let project = app.project {
                HStack(spacing: 8) {
                    Text(app.current?.session.title ?? project.lastPathComponent)
                        .font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    if app.git.isRepo {
                        Label(app.git.branch ?? "detached", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text3).lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 8)
            if app.keepingAwake {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .help("Keeping the Mac awake while Anvil works")
            }
            if let c = app.current {
                if c.session.usage.calls > 0 {
                    Text(Fmt.dollars(c.session.usage.cost)).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.text3).help(c.session.usage.line)
                }
                ChangesPill(controller: c)
            }
            // Split, but too narrow for two panes: this switches which one is shown.
            if app.panes.isSplit && !app.splitFits {
                Button { app.focusOtherPane() } label: {
                    Label("2 panes", systemImage: "rectangle.split.2x1")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text2)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.surface2, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Too narrow to show both sessions. Click to switch the pane shown. Widen the window to see both.")
            }
            IconButton(symbol: "sidebar.right", help: "Inspector (⌥⌘I)") {
                app.showInspector.toggle()
                if !app.showInspector { app.inspectorDismissed = true }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Theme.topBar)
    }
}

/// "+12 −3 · 2 files": opens the diff review.
struct ChangesPill: View {
    @Environment(AppState.self) private var app
    let controller: SessionController

    var body: some View {
        let diffs = controller.changedDiffs
        if !diffs.isEmpty {
            let files = Set(diffs.map(\.path)).count
            Button {
                app.inspectorTab = .changes
                app.showInspector = true
            } label: {
                HStack(spacing: 6) {
                    Text("+\(diffs.reduce(0) { $0 + $1.added })").foregroundStyle(Theme.green)
                    Text("−\(diffs.reduce(0) { $0 + $1.removed })").foregroundStyle(Theme.red)
                    Text("\(files) file\(files == 1 ? "" : "s")").foregroundStyle(Theme.text2)
                }
                .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.surface2, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Review changes")
        }
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image("Logo").resizable().scaledToFit().frame(width: 72, height: 72)
            Text("Welcome to \(AppInfo.name)").font(.system(size: 26, weight: .semibold))
            Text("Open a project folder to start coding with the agent.").foregroundStyle(Theme.text2)
            Button { app.chooseProject() } label: { Label("Open Folder", systemImage: "folder") }
                .buttonStyle(Pill(kind: .primary)).keyboardShortcut("o")
            let recent = RecentProjects.list()
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECENT").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3).padding(.leading, 10).padding(.bottom, 4)
                    ForEach(recent.prefix(5), id: \.path) { u in
                        Button { app.open(u) } label: {
                            HoverRow {
                                HStack {
                                    Image(systemName: "folder").foregroundStyle(Theme.text3)
                                    Text(u.lastPathComponent).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text(Paths.display(u.deletingLastPathComponent(), root: nil)).font(.caption).foregroundStyle(Theme.text3).lineLimit(1)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)
                .padding(.top, 10)
            }
            if !AppSettings.shared.ready(model: AppSettings.shared.model) {
                Text("The selected model's provider isn't set up yet. Open Settings (⌘,).").font(.callout).foregroundStyle(Theme.amber)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
