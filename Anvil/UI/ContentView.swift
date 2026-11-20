import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            Group {
                if let c = app.current {
                    ConversationView(controller: c).id(c.session.id)
                } else {
                    WelcomeView()
                }
            }
            .inspector(isPresented: $app.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 280, ideal: 380, max: 600)
            }
        }
        .navigationTitle(app.project?.lastPathComponent ?? AppInfo.name)
        .navigationSubtitle(app.git.isRepo ? app.git.summary : "")
        .toolbar {
            if let c = app.current {
                ToolbarItemGroup(placement: .primaryAction) {
                    ModeMenu(controller: c)
                    ModelButton(controller: c)
                    Text(c.session.usage.calls > 0 ? Fmt.dollars(c.session.usage.cost) : "")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .help(c.session.usage.line)
                    Button { app.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle inspector")
                }
            }
        }
        .sheet(isPresented: $app.showModelPicker) {
            if let c = app.current { ModelPickerSheet(controller: c) }
        }
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hammer").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text(AppInfo.name).font(.largeTitle.weight(.semibold))
            Text("Open a project folder to start a coding session.").foregroundStyle(.secondary)
            Button("Open Folder…") { app.chooseProject() }.buttonStyle(.borderedProminent).controlSize(.large)
            let recent = RecentProjects.list()
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent").font(.caption).foregroundStyle(.secondary)
                    ForEach(recent.prefix(6), id: \.path) { u in
                        Button { app.open(u) } label: { Label(Paths.display(u, root: nil), systemImage: "folder") }.buttonStyle(.link)
                    }
                }.padding(.top, 8)
            }
            if !AppSettings.shared.hasKey {
                Text("No API key yet. Add one in Settings (⌘,).").font(.callout).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ModeMenu: View {
    let controller: SessionController
    var body: some View {
        Menu {
            ForEach(PermissionMode.allCases) { m in
                Button { controller.mode = m } label: { Label(m.label, systemImage: m.symbol) }
            }
        } label: {
            Label(controller.mode.short, systemImage: controller.mode.symbol)
                .labelStyle(.titleAndIcon)
        }
        .help("Permission mode (⇧⌘M cycles). Dangerous commands always ask.")
        .tint(controller.mode == .bypass ? .red : controller.mode == .plan ? .blue : nil)
    }
}

struct ModelButton: View {
    @Environment(AppState.self) private var app
    let controller: SessionController
    var body: some View {
        Button { app.showModelPicker = true } label: {
            Label(controller.model, systemImage: "cpu").labelStyle(.titleAndIcon).lineLimit(1)
        }
        .help("Model for this session (effort: \(AppSettings.shared.effort))")
    }
}
