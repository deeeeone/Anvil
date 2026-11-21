import WebKit
import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                InspectorTabs()
                Spacer(minLength: 4)
                IconButton(symbol: "xmark", help: "Close") { app.showInspector = false; app.inspectorDismissed = true }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.topBar)
            Hairline()
            Group {
                if let c = app.current {
                    switch app.inspectorTab ?? .changes {
                    case .changes: ChangesPane(controller: c)
                    case .preview: PreviewPane()
                    case .device: DevicePane()
                    case .files: FilesPane(root: c.root).id(c.root.path)
                    case .todo: TodoPane(controller: c)
                    case .terminal: TerminalPane(controller: c)
                    case .git: GitPane(controller: c)
                    }
                } else {
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.panel)
    }
}

struct InspectorTabs: View {
    @Environment(AppState.self) private var app
    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs(labels: true)
            tabs(labels: false)
        }
    }
    func tabs(labels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(InspectorTab.allCases) { t in
                let on = (app.inspectorTab ?? .changes) == t
                Button { app.inspectorTab = t } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.symbol).font(.system(size: 11, weight: .semibold))
                        if labels { Text(t.rawValue).font(.system(size: 12, weight: .medium)) }
                    }
                    .foregroundStyle(on ? Theme.text : Theme.text3)
                    .padding(.horizontal, labels ? 10 : 8).padding(.vertical, 6)
                    .background(on ? Theme.surface2 : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(t.rawValue)
            }
        }
        .fixedSize()
    }
}

struct EmptyPane: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light)).foregroundStyle(Theme.text3)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ChangesPane: View {
    @Environment(AppState.self) private var app
    let controller: SessionController

    /// The latest diff per file, newest first.
    var files: [FileDiff] {
        var seen = Set<String>()
        return controller.changedDiffs.reversed().filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        let all = controller.changedDiffs
        if all.isEmpty {
            EmptyPane(symbol: "plusminus", title: "No changes yet", detail: "Every edit the agent makes shows up here as a diff you can review.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(files) { d in
                            let selected = (app.selectedDiff ?? all.last)?.path == d.path
                            Button { app.selectedDiff = all.last { $0.path == d.path } } label: {
                                HoverRow(selected: selected) {
                                    HStack(spacing: 8) {
                                        Image(systemName: d.isNew ? "doc.badge.plus" : d.isDeleted ? "trash" : "doc.text")
                                            .font(.system(size: 11)).foregroundStyle(d.isNew ? Theme.green : d.isDeleted ? Theme.red : Theme.text3)
                                        Text(d.path).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                        Spacer(minLength: 4)
                                        Text("+\(d.added)").foregroundStyle(Theme.green)
                                        Text("−\(d.removed)").foregroundStyle(Theme.red)
                                    }
                                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: min(CGFloat(files.count) * 32 + 16, 170))
                Hairline()
                if let d = app.selectedDiff ?? all.last {
                    DiffView(unified: d.unified).padding(10)
                }
                CheckpointBar(controller: controller)
            }
        }
    }
}

struct CheckpointBar: View {
    let controller: SessionController
    var body: some View {
        let open = controller.session.checkpoints.filter { !$0.restored }
        if !open.isEmpty {
            HStack(spacing: 8) {
                Menu {
                    ForEach(open.reversed()) { cp in
                        Button("Before: \(cp.label) (\(cp.files.count) files)") { controller.undo(to: cp.id) }
                    }
                } label: {
                    Label("Checkpoints", systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Theme.border))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Spacer(minLength: 4)
                Button { controller.undoLast() } label: { Label("Undo last task", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(Pill(kind: .secondary, compact: true)).disabled(controller.running)
            }
            .padding(10)
            .background(Theme.panel)
            .overlay(alignment: .top) { Hairline() }
        }
    }
}

struct FilesPane: View {
    @Environment(AppState.self) private var app
    let root: URL
    var body: some View {
        if let file = app.previewFile {
            FilePreview(url: file, root: root) { app.previewFile = nil }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FileTree(url: root, root: root, depth: 0)
                    if ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
                        let _ = app.fileTick
                        Text("This folder is empty. Files the agent creates show up here as they're written.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.text3).padding(10)
                    }
                }
                .padding(8)
            }
        }
    }
}

struct FileTree: View {
    @Environment(AppState.self) private var app
    let url: URL
    let root: URL
    let depth: Int
    @State private var expanded: Set<String> = []

    var body: some View {
        ForEach(children, id: \.path) { child in
            let dir = isDir(child)
            Button {
                if dir { if expanded.contains(child.path) { expanded.remove(child.path) } else { expanded.insert(child.path) } }
                else { app.previewFile = child }
            } label: {
                HoverRow {
                    HStack(spacing: 6) {
                        Image(systemName: dir ? (expanded.contains(child.path) ? "chevron.down" : "chevron.right") : "doc")
                            .font(.system(size: dir ? 9 : 11, weight: dir ? .bold : .regular)).foregroundStyle(Theme.text3).frame(width: 12)
                        Text(child.lastPathComponent).font(.system(size: 12.5)).foregroundStyle(dir ? Theme.text : Theme.text2).lineLimit(1)
                    }
                    .padding(.leading, CGFloat(depth) * 14)
                }
            }
            .buttonStyle(.plain)
            if dir && expanded.contains(child.path) {
                FileTree(url: child, root: root, depth: depth + 1)
            }
        }
    }

    private var children: [URL] {
        _ = app.fileTick   // re-list when files change
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

struct FilePreview: View {
    @Environment(AppState.self) private var app
    let url: URL
    let root: URL
    let close: () -> Void
    var body: some View {
        let _ = app.fileTick   // live: reload when the file changes
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", help: "Back to files") { close() }
                Text(Paths.display(url, root: root)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.up.forward.app", help: "Open in the default editor") { NSWorkspace.shared.open(url) }
            }
            .padding(8)
            Hairline()
            ScrollView([.vertical, .horizontal]) {
                let text = (try? FileTools.readText(url)) ?? "(can't preview this file)"
                let (body, _, _, _) = FileTools.numbered(text, offset: 1, limit: 3000)
                Text(body.isEmpty ? "(empty)" : body).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2).textSelection(.enabled).padding(12)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .background(Theme.code)
        }
    }
}

struct TodoPane: View {
    let controller: SessionController
    var body: some View {
        let plan = controller.session.plan
        let todos = controller.session.todos
        if plan == nil && todos.isEmpty {
            EmptyPane(symbol: "checklist", title: "No plan yet", detail: "Big tasks start with a plan you approve. Milestones and todos tick off here as the agent works.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let plan {
                        section("PLAN · \(plan.done.count)/\(plan.steps.count)") {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, s in
                                row(s, done: plan.done.contains(i + 1), active: plan.state == .approved && plan.done.count == i)
                            }
                        }
                    }
                    if !todos.isEmpty {
                        section("TODOS · \(todos.filter { $0.status == .completed }.count)/\(todos.count)") {
                            ForEach(todos) { t in row(t.content, done: t.status == .completed, active: t.status == .inProgress) }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3)
            content()
        }
    }

    func row(_ s: String, done: Bool, active: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : active ? "circle.dotted.circle" : "circle")
                .foregroundStyle(done ? Theme.green : active ? Theme.accent : Theme.text3)
            Text(s).font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(done ? Theme.text3 : Theme.text).strikethrough(done, color: Theme.text3)
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        box.addSubview(view)
        view.frame = box.bounds
        view.autoresizingMask = [.width, .height]
        return box
    }
    func updateNSView(_ box: NSView, context: Context) {
        if view.superview !== box {
            box.subviews.forEach { $0.removeFromSuperview() }
            box.addSubview(view)
            view.frame = box.bounds
            view.autoresizingMask = [.width, .height]
        }
    }
}

/// Terminal tabs: the agent's commands, one per background process, and your own shells (⌘T-style "+").
struct TerminalPane: View {
    @Environment(AppState.self) private var app
    let controller: SessionController

    var body: some View {
        let store = app.terminals
        let selected = store.tabs.first { $0.id == store.selected } ?? store.agentTab
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { t in
                        let on = t.id == selected.id
                        HStack(spacing: 6) {
                            Image(systemName: t.kind == .agent ? "sparkles" : t.kind == .shell ? "terminal" : "play.rectangle")
                                .font(.system(size: 10, weight: .semibold))
                            Text(t.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if case .process = t.kind { Circle().fill(t.running ? Theme.green : Theme.text3).frame(width: 6, height: 6) }
                            if t.kind == .shell && !t.running { Text("exited").font(.system(size: 10)).foregroundStyle(Theme.text3) }
                            if t.kind != .agent {
                                Button { store.close(t.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(Theme.text3)
                            }
                        }
                        .foregroundStyle(on ? Theme.text : Theme.text3)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(on ? Theme.surface2 : .clear, in: Capsule())
                        .contentShape(Capsule())
                        .onTapGesture { store.selected = t.id }
                    }
                    IconButton(symbol: "plus", help: "New shell in the project folder") { store.newShell() }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            Hairline()
            TerminalHost(view: store.view(for: selected, cwd: controller.root))
                .id(selected.id)
                .background(Theme.code)
        }
        .onAppear { store.syncProcesses(controller.processes.entries) }
        .onChange(of: controller.processes.tick) { _, _ in store.syncProcesses(controller.processes.entries) }
    }
}

/// A live view of the booted iOS simulator. Click the screen to tap it (with AXe installed).
struct DevicePane: View {
    @Environment(AppState.self) private var app
    @State private var booting = false

    var body: some View {
        let sim = app.simulator
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "iphone").foregroundStyle(Theme.text3)
                Text(sim.device.map { "\($0.name) · \($0.runtime)" } ?? "No simulator booted").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if sim.device != nil {
                    IconButton(symbol: "house", help: "Home button") { Task { await sim.home() } }
                }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await sim.refresh() } }
            }
            .padding(8)
            Hairline()
            if let img = sim.image {
                GeometryReader { geo in
                    let fit = fitted(img.size, in: geo.size)
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: fit.width, height: fit.height)
                        .clipShape(RoundedRectangle(cornerRadius: fit.width * 0.11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: fit.width * 0.11, style: .continuous).stroke(Theme.borderStrong, lineWidth: 2))
                        .onTapGesture { p in Task { await sim.tap(unit: CGPoint(x: p.x / fit.width, y: p.y / fit.height)) } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(16)
                if !sim.axeAvailable {
                    Text("Install AXe so you and the agent can tap, type and read the screen's elements: \(Sim.installAXe)")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.amber).padding(10).textSelection(.enabled)
                }
            } else {
                VStack(spacing: 12) {
                    EmptyPane(symbol: "iphone", title: "iOS Simulator",
                              detail: sim.note.isEmpty ? "Ask the agent to build and run your iOS app, or boot a simulator here. You'll see it live, and the agent drives it." : sim.note)
                    if sim.note.contains("no simulator is booted") {
                        Button(booting ? "Booting…" : "Boot an iPhone") {
                            booting = true
                            Task {
                                let ctx = ToolContext(root: Paths.home, processes: app.processes, host: nil)
                                _ = try? await SimulatorTools.boot.run?(.object([:]), ctx)
                                booting = false
                                await sim.refresh()
                            }
                        }
                        .buttonStyle(Pill(kind: .primary)).disabled(booting)
                    }
                    Spacer()
                }
            }
        }
        .task {
            // Live view: refresh while the tab is open.
            while !Task.isCancelled {
                await sim.refresh()
                try? await Task.sleep(for: .seconds(sim.device == nil ? 5 : 1.2))
            }
        }
    }

    func fitted(_ img: CGSize, in box: CGSize) -> CGSize {
        guard img.width > 0, img.height > 0 else { return box }
        let s = min(box.width / img.width, box.height / img.height)
        return CGSize(width: img.width * s, height: img.height * s)
    }
}

struct GitPane: View {
    @Environment(AppState.self) private var app
    let controller: SessionController
    @State private var selected: String?
    @State private var diffText = ""
    @State private var message = ""
    @State private var busy = false
    @State private var log = ""
    @State private var note = ""

    var body: some View {
        let st = app.git
        VStack(alignment: .leading, spacing: 0) {
            if !st.isRepo {
                VStack(spacing: 12) {
                    EmptyPane(symbol: "arrow.triangle.branch", title: "Not a git repository", detail: "Initialise one to track and commit changes.")
                    Button("Initialise git") { Task { _ = await Git.initRepo(controller.root); app.refreshGit() } }.buttonStyle(Pill(kind: .primary))
                    Spacer()
                }
            } else {
                HStack(spacing: 8) {
                    Label(st.branch ?? "detached", systemImage: "arrow.triangle.branch").font(.system(size: 13, weight: .semibold))
                    if st.ahead > 0 { Text("↑\(st.ahead)").font(.system(size: 11.5)).foregroundStyle(Theme.text3) }
                    if st.behind > 0 { Text("↓\(st.behind)").font(.system(size: 11.5)).foregroundStyle(Theme.text3) }
                    Spacer()
                    if controller.session.branch != nil {
                        Button("Merge into \(controller.session.baseBranch ?? "base")") {
                            busy = true
                            Task { note = await controller.mergeWorktree(); busy = false; loadLog() }
                        }
                        .buttonStyle(Pill(kind: .secondary, compact: true)).disabled(busy || !st.files.isEmpty)
                        .help(st.files.isEmpty ? "Merge this session's branch into the project" : "Commit first")
                    }
                    IconButton(symbol: "arrow.clockwise", help: "Refresh") { app.refreshGit(); loadDiff(); loadLog() }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Hairline()
                if st.files.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Working tree clean", systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(Theme.green)
                        if !log.isEmpty {
                            Text("RECENT COMMITS").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.text3).padding(.top, 6)
                            Text(log).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2).textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(14)
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(st.files) { f in
                                Button { selected = selected == f.path ? nil : f.path } label: {
                                    HoverRow(selected: selected == f.path) {
                                        HStack(spacing: 8) {
                                            Text(f.letter).font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundStyle(f.isUntracked ? Theme.green : f.isStaged ? Theme.blue : Theme.amber).frame(width: 14)
                                            Text(f.path).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                            Spacer(minLength: 4)
                                            Text(f.label).font(.system(size: 11)).foregroundStyle(Theme.text3)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: min(CGFloat(st.files.count) * 32 + 16, 180))
                    Hairline()
                    DiffView(unified: diffText.isEmpty ? "(no diff)" : diffText).padding(10)
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Commit message", text: $message, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...6)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .card(12, fill: Theme.surface)
                        HStack(spacing: 8) {
                            Button { generate() } label: { Label("Write message", systemImage: "sparkles") }
                                .buttonStyle(Pill(kind: .secondary, compact: true)).disabled(busy)
                            if busy { Spinner().scaleEffect(0.8) }
                            Spacer(minLength: 4)
                            Button("Commit all") { commit() }.buttonStyle(Pill(kind: .primary, compact: true))
                                .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        }
                        if !note.isEmpty { Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.text3).textSelection(.enabled) }
                    }
                    .padding(12)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
        }
        .onAppear { app.refreshGit(); loadDiff(); loadLog() }
        .onChange(of: selected) { _, _ in loadDiff() }
    }

    func loadDiff() {
        Task {
            if let s = selected, let f = app.git.files.first(where: { $0.path == s }) {
                if f.isUntracked {
                    let content = (try? String(contentsOf: controller.root.appendingPathComponent(s), encoding: .utf8)) ?? ""
                    diffText = DiffEngine.unified(old: "", new: content, path: s)
                } else {
                    diffText = await Git.diff(controller.root, path: s) + (await Git.diff(controller.root, path: s, staged: true))
                }
            } else {
                diffText = await Git.diff(controller.root)
            }
        }
    }

    func loadLog() { Task { log = await Git.log(controller.root, count: 8) } }

    func generate() {
        busy = true
        Task {
            do { message = try await controller.generateCommitMessage(); note = "" }
            catch { note = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            busy = false
        }
    }

    func commit() {
        busy = true
        Task {
            _ = await Git.stageAll(controller.root)
            let r = await Git.commit(controller.root, message: message)
            note = r.status == 0 ? "Committed." : r.combined
            if r.status == 0 { message = "" }
            busy = false
            app.refreshGit(); loadLog(); loadDiff()
        }
    }
}


struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The embedded browser: a live preview of the dev server, which the agent can also drive.
struct PreviewPane: View {
    @Environment(AppState.self) private var app
    @State private var address = ""

    var body: some View {
        let b = app.browser
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                IconButton(symbol: "chevron.left", help: "Back") { b.webView.goBack() }
                IconButton(symbol: "chevron.right", help: "Forward") { b.webView.goForward() }
                IconButton(symbol: b.loading ? "xmark" : "arrow.clockwise", help: "Reload") { b.loading ? b.webView.stopLoading() : b.reload() }
                TextField("localhost:3000 or any URL", text: $address)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .card(9, fill: Theme.surface)
                    .onSubmit { Task { await b.open(address) } }
                IconButton(symbol: "safari", help: "Open in Safari") { if let u = URL(string: b.url), !b.url.isEmpty { NSWorkspace.shared.open(u) } }
            }
            .padding(8)
            Hairline()
            ZStack {
                Group {
                    if let w = b.viewportWidth {
                        // Emulated device size, centred.
                        WebViewHost(webView: b.webView)
                            .frame(width: w, height: b.viewportHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.borderStrong))
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.code)
                    } else {
                        WebViewHost(webView: b.webView)
                    }
                }
                if b.url.isEmpty {
                    EmptyPane(symbol: "safari", title: "No page yet",
                              detail: "When the agent starts a dev server, it opens here and reloads after each edit. The agent can click, type and take screenshots in this browser. Or type a URL above.")
                        .background(Theme.panel)
                }
            }
            if let e = b.lastError { Text(e).font(.system(size: 11.5)).foregroundStyle(Theme.amber).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .onAppear { address = b.url }
        .onChange(of: b.url) { _, u in address = u }
    }
}
