import SwiftUI

struct InspectorView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { app.inspectorTab ?? .changes }, set: { app.inspectorTab = $0 })) {
                ForEach(InspectorTab.allCases) { t in Label(t.rawValue, systemImage: t.symbol).tag(t) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(10)
            Divider()
            if let c = app.current {
                switch app.inspectorTab ?? .changes {
                case .changes: ChangesPane(controller: c)
                case .todo: TodoPane(controller: c)
                case .terminal: TerminalPane(controller: c)
                case .git: GitPane(controller: c)
                }
            } else {
                Spacer()
            }
        }
    }
}

struct ChangesPane: View {
    @Environment(AppState.self) private var app
    let controller: SessionController

    var body: some View {
        let diffs = controller.changedDiffs
        VStack(alignment: .leading, spacing: 0) {
            if let file = app.previewFile {
                FilePreview(url: file, root: controller.root) { app.previewFile = nil }
            } else if diffs.isEmpty {
                ContentUnavailableView("No changes yet", systemImage: "plusminus", description: Text("Every edit the agent makes shows up here as a diff."))
            } else {
                List(selection: Binding(get: { app.selectedDiff?.id }, set: { id in app.selectedDiff = diffs.first { $0.id == id } })) {
                    ForEach(diffs.reversed()) { d in
                        HStack {
                            Image(systemName: d.isNew ? "doc.badge.plus" : d.isDeleted ? "trash" : "pencil").foregroundStyle(.secondary)
                            Text(d.path).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text(d.statLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }.tag(d.id)
                    }
                }
                .frame(height: min(CGFloat(diffs.count) * 26 + 16, 180))
                Divider()
                if let d = app.selectedDiff ?? diffs.last {
                    DiffView(unified: d.unified).padding(8)
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
            HStack {
                Menu {
                    ForEach(open.reversed()) { cp in
                        Button("Undo back to before: \(cp.label) (\(cp.files.count) files)") { controller.undo(to: cp.id) }
                    }
                } label: { Label("Checkpoints", systemImage: "clock.arrow.circlepath") }
                .fixedSize()
                Spacer()
                Button("Undo last task") { controller.undoLast() }.disabled(controller.running)
            }
            .padding(10)
            .background(.bar)
        }
    }
}

struct FilePreview: View {
    let url: URL
    let root: URL
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Paths.display(url, root: root)).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.borderless).help("Open in default editor")
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }.padding(10)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                let text = (try? FileTools.readText(url)) ?? "(can't preview this file)"
                let (body, _, _, _) = FileTools.numbered(text, offset: 1, limit: 3000)
                Text(body.isEmpty ? "(empty)" : body).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).padding(10)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

struct TodoPane: View {
    let controller: SessionController
    var body: some View {
        let plan = controller.session.plan
        let todos = controller.session.todos
        if plan == nil && todos.isEmpty {
            ContentUnavailableView("No plan yet", systemImage: "checklist", description: Text("Big tasks start with a plan of milestones you approve. They tick off here as the agent works."))
        } else {
            List {
                if let plan {
                    Section("Plan (\(plan.done.count)/\(plan.steps.count))") {
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, s in
                            Label { Text(s).strikethrough(plan.done.contains(i + 1)) } icon: {
                                Image(systemName: plan.done.contains(i + 1) ? "checkmark.circle.fill" : "circle").foregroundStyle(plan.done.contains(i + 1) ? .green : .secondary)
                            }
                        }
                    }
                }
                if !todos.isEmpty {
                    Section("Todos (\(todos.filter { $0.status == .completed }.count)/\(todos.count))") {
                        ForEach(todos) { t in
                            Label { Text(t.content).strikethrough(t.status == .completed).fontWeight(t.status == .inProgress ? .semibold : .regular) } icon: {
                                Image(systemName: t.status == .completed ? "checkmark.circle.fill" : t.status == .inProgress ? "circle.dotted.circle" : "circle")
                                    .foregroundStyle(t.status == .completed ? .green : t.status == .inProgress ? Color.accentColor : .secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct TerminalPane: View {
    let controller: SessionController
    @State private var selectedProcess: String?

    var body: some View {
        let procs = controller.processes.entries
        VStack(spacing: 0) {
            if !procs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background processes").font(.caption).foregroundStyle(.secondary)
                    ForEach(procs) { p in
                        HStack {
                            Circle().fill(p.running ? .green : .secondary).frame(width: 7, height: 7)
                            Button(p.name) { selectedProcess = selectedProcess == p.name ? nil : p.name }.buttonStyle(.link)
                            Text(p.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            if p.running { Button("Stop") { _ = controller.processes.stop(p.name) }.controlSize(.small) }
                            else { Text("exit \(p.exitCode ?? 0)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .padding(10)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let name = selectedProcess, let p = controller.processes.entry(name) {
                            let _ = controller.processes.tick
                            Text("\(p.name) output").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(String(p.output.value.suffix(60_000))).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        } else if controller.terminal.isEmpty {
                            Text("Shell output from the agent's commands streams here.").foregroundStyle(.secondary).padding(.top, 20)
                        } else {
                            ForEach(controller.terminal) { t in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(t.title).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accentColor)
                                    Text(t.text.isEmpty ? "…" : String(t.text.suffix(40_000))).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .onChange(of: controller.terminal.last?.text.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
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
                ContentUnavailableView {
                    Label("Not a git repository", systemImage: "arrow.triangle.branch")
                } description: { Text("Initialise one to track and commit changes.") } actions: {
                    Button("git init") { Task { _ = await Git.initRepo(controller.root); app.refreshGit() } }
                }
            } else {
                HStack {
                    Label(st.branch ?? "detached", systemImage: "arrow.triangle.branch").font(.headline)
                    if let up = st.upstream { Text(up).font(.caption).foregroundStyle(.secondary) }
                    if st.ahead > 0 { Text("↑\(st.ahead)").font(.caption) }
                    if st.behind > 0 { Text("↓\(st.behind)").font(.caption) }
                    Spacer()
                    Button { app.refreshGit(); loadDiff() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }.padding(10)
                Divider()
                if st.files.isEmpty {
                    Text("Working tree clean.").foregroundStyle(.secondary).padding(10)
                    if !log.isEmpty { Text(log).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.horizontal, 10).textSelection(.enabled) }
                    Spacer()
                } else {
                    List(selection: $selected) {
                        ForEach(st.files) { f in
                            HStack {
                                Text(f.letter).font(.caption.monospaced().weight(.bold)).foregroundStyle(f.isUntracked ? .green : f.isStaged ? .blue : .orange).frame(width: 14)
                                Text(f.path).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(f.label).font(.caption).foregroundStyle(.secondary)
                            }.tag(f.path)
                        }
                    }
                    .frame(height: min(CGFloat(st.files.count) * 26 + 16, 200))
                    Divider()
                    DiffView(unified: diffText.isEmpty ? "(select a file to see its diff)" : diffText).padding(8)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Commit message", text: $message, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...6)
                        HStack {
                            Button { generate() } label: { Label("Generate", systemImage: "sparkles") }.disabled(busy)
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                            Button("Stage all and commit") { commit() }.buttonStyle(.borderedProminent).disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        }
                        if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(10)
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
