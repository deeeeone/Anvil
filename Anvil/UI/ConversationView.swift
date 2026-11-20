import SwiftUI

/// Consecutive work rows (thoughts, progress lines, tool steps) fold into one group.
enum Segment: Identifiable {
    case item(ChatItem)
    case work([ChatItem])
    var id: UUID {
        switch self { case .item(let i): return i.id; case .work(let l): return l[0].id }
    }

    static func build(_ items: [ChatItem]) -> [Segment] {
        var out: [Segment] = []
        var work: [ChatItem] = []
        func flush() { if !work.isEmpty { out.append(.work(work)); work = [] } }
        for i in items {
            let isWork = i.kind == .tool || i.kind == .thought || (i.kind == .assistant && !i.final)
            if isWork { work.append(i) } else { flush(); out.append(.item(i)) }
        }
        flush()
        return out
    }
}

struct ConversationView: View {
    @Environment(AppState.self) private var app
    let controller: SessionController

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if controller.session.items.isEmpty { EmptySessionView(controller: controller) }
                        let segments = Segment.build(controller.session.items)
                        ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                            switch seg {
                            case .item(let item): ItemView(item: item, controller: controller)
                            case .work(let items): WorkGroup(items: items, live: controller.running && idx == segments.count - 1)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                    .frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: controller.session.items.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: controller.pendingPermission?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let p = controller.pendingPermission {
                PermissionCard(pending: p, controller: controller).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let q = controller.pendingQuestion {
                QuestionCard(pending: q).padding(.horizontal, 16).padding(.bottom, 8)
            }
            StatusBar(controller: controller)
            Composer(controller: controller)
        }
    }
}

struct EmptySessionView: View {
    let controller: SessionController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should we build?").font(.title2.weight(.semibold))
            Text("Describe a feature, a bug or a question about \(controller.root.lastPathComponent). Big tasks start with a plan you approve. Type / for commands.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(["/init", "Explain this codebase", "Find and fix failing tests"], id: \.self) { s in
                    Button(s) { controller.send(s) }.buttonStyle(.bordered)
                }
            }
            if ProjectContext.memory(controller.root).isEmpty {
                Text("Tip: /init writes an AGENTS.md so every session starts with the project's commands and conventions.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .padding(.top, 40)
    }
}

struct ItemView: View {
    let item: ChatItem
    let controller: SessionController

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.text).textSelection(.enabled)
                    if item.images > 0 { Label("\(item.images) image(s)", systemImage: "photo").font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            MarkdownText(text: item.text).textSelection(.enabled)
        case .plan:
            if let plan = item.plan { PlanCardView(plan: plan, itemID: item.id, controller: controller) }
        case .system:
            Text(item.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .error:
            Label { Text(item.text).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .thought, .tool:
            WorkGroup(items: [item], live: false)
        }
    }
}

/// Folded, readable tool steps.
struct WorkGroup: View {
    let items: [ChatItem]
    let live: Bool
    @State private var expanded: Bool?

    private var isExpanded: Bool { expanded ?? (live || items.count <= 6) }

    var summary: String {
        let tools = items.compactMap(\.tool)
        var reads = 0, edits = 0, cmds = 0, searches = 0, other = 0
        for t in tools {
            switch t.name {
            case "read_file", "list_dir": reads += 1
            case "edit_file", "multi_edit", "write_file", "delete_file": edits += 1
            case "shell", "start_process": cmds += 1
            case "grep", "glob", "web_search", "fetch_url": searches += 1
            default: other += 1
            }
        }
        var parts: [String] = []
        if reads > 0 { parts.append("read \(reads)") }
        if searches > 0 { parts.append("searched \(searches)") }
        if edits > 0 { parts.append("edited \(edits)") }
        if cmds > 0 { parts.append("ran \(cmds) command\(cmds == 1 ? "" : "s")") }
        if other > 0 { parts.append("\(other) other") }
        let failed = tools.filter { $0.status == .failed || $0.status == .denied }.count
        return (parts.isEmpty ? "Thinking" : parts.joined(separator: ", ").capitalizedFirst) + (failed > 0 ? " · \(failed) failed" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if items.count > 1 {
                Button { withAnimation(.snappy(duration: 0.2)) { expanded = !isExpanded } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(isExpanded ? 90 : 0)).font(.caption2.weight(.bold))
                        Text(summary).font(.callout.weight(.medium))
                        if live { ProgressView().controlSize(.mini) }
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if isExpanded || items.count == 1 {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(items) { i in
                        switch i.kind {
                        case .tool: ToolRow(item: i)
                        case .thought:
                            Text(i.text).font(.callout).foregroundStyle(.tertiary).italic().lineLimit(4).textSelection(.enabled)
                                .padding(.leading, 2)
                        default:
                            Text(i.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, items.count > 1 ? 14 : 0)
                .overlay(alignment: .leading) {
                    if items.count > 1 { Rectangle().fill(.quaternary).frame(width: 1).padding(.leading, 4) }
                }
            }
        }
    }
}

struct ToolRow: View {
    @Environment(AppState.self) private var app
    let item: ChatItem
    @State private var open = false

    var icon: String {
        switch item.tool?.name ?? "" {
        case "read_file": return "doc.text"
        case "edit_file", "multi_edit": return "pencil"
        case "write_file": return "doc.badge.plus"
        case "delete_file": return "trash"
        case "shell": return "terminal"
        case "start_process", "read_process", "stop_process", "list_processes": return "play.rectangle"
        case "grep", "glob": return "magnifyingglass"
        case "list_dir": return "folder"
        case "web_search", "fetch_url": return "globe"
        case "todo_write": return "checklist"
        case "wait_until", "wait": return "hourglass"
        case "ask_user": return "questionmark.bubble"
        default: return "wrench.and.screwdriver"
        }
    }

    var body: some View {
        if let t = item.tool {
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.snappy(duration: 0.18)) { open.toggle() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
                        Text(t.summary).font(.system(.callout, design: t.name == "shell" ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
                        ForEach(t.diffs) { d in
                            Text(d.statLabel).font(.caption.monospacedDigit())
                                .foregroundStyle(d.isDeleted ? .red : .green)
                        }
                        Spacer(minLength: 4)
                        if let dur = t.duration, dur >= 1 { Text(String(format: "%.0fs", dur)).font(.caption2).foregroundStyle(.tertiary) }
                        statusIcon(t.status)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    if !t.diffs.isEmpty {
                        ForEach(t.diffs) { d in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(d.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Open in Inspector") { app.selectedDiff = d; app.previewFile = nil; app.inspectorTab = .changes; app.showInspector = true }
                                        .buttonStyle(.link).font(.caption)
                                }
                                DiffView(unified: d.unified, compact: true).frame(maxHeight: 320)
                            }
                        }
                    }
                    if !t.output.isEmpty && (t.diffs.isEmpty || t.status != .ok) {
                        ScrollView {
                            Text(t.output).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        .frame(maxHeight: 260)
                        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    @ViewBuilder func statusIcon(_ s: ToolStep.Status) -> some View {
        switch s {
        case .running: ProgressView().controlSize(.mini)
        case .ok: Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.red)
        case .denied: Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct PlanCardView: View {
    let plan: PlanCard
    let itemID: UUID
    let controller: SessionController
    @State private var revision = ""

    var pending: Bool { controller.pendingPlan?.itemID == itemID }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Plan", systemImage: "list.bullet.clipboard").font(.headline)
                Spacer()
                Text(plan.state == .pending ? (pending ? "waiting for you" : "not approved") : plan.state.rawValue)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: plan.done.contains(i + 1) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(plan.done.contains(i + 1) ? .green : .secondary)
                    Text("\(s)").strikethrough(plan.done.contains(i + 1), color: .secondary)
                }
            }
            if pending, let p = controller.pendingPlan {
                TextField("Ask for changes (optional)", text: $revision, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                HStack {
                    if !revision.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Revise plan") { p.resume(.revise(revision)) }.keyboardShortcut(.return)
                    } else {
                        Button("Approve") { p.resume(.approve) }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
                        Button("Approve and auto-accept edits") { p.resume(.approveAutoEdits) }
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { p.resume(.cancel) }
                }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(pending ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
    }
}

struct PermissionCard: View {
    let pending: PendingPermission
    let controller: SessionController
    @State private var note = ""

    var body: some View {
        let r = pending.request
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: r.command != nil ? "terminal" : "pencil").foregroundStyle(Color.accentColor)
                Text(title(r)).font(.headline)
                Spacer()
                if r.reason != "edit" && r.reason != "run command" {
                    Text(r.reason).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            if let cmd = r.command {
                Text(cmd).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            if !r.diffs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(r.diffs) { d in
                            Text("\(d.path)  \(d.statLabel)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            DiffView(unified: d.unified, compact: true)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            TextField("Tell the agent what to do instead (optional, used if you decline)", text: $note).textFieldStyle(.roundedBorder)
            HStack {
                Button("Allow") { pending.resume(.allow) }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
                if r.command != nil {
                    if let key = r.commandKey, Permissions.dangerReason(r.command ?? "") == nil {
                        Button("Always allow \u{201C}\(key)\u{201D} this session") { pending.resume(.allowSession) }
                    }
                } else {
                    Button("Allow all edits this session") { pending.resume(.allowSession) }
                }
                Spacer()
                Button("Decline") { pending.resume(.deny(note.isEmpty ? nil : note)) }.keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    func title(_ r: PermissionRequest) -> String {
        if r.command != nil { return r.tool == "start_process" ? "Start this background process?" : "Run this command?" }
        if r.diffs.count == 1, let d = r.diffs.first { return d.isNew ? "Create \(d.path)?" : d.isDeleted ? "Delete \(d.path)?" : "Edit \(d.path)?" }
        return "Apply edits to \(r.diffs.count) files?"
    }
}

struct QuestionCard: View {
    let pending: PendingQuestion
    @State private var answer = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(pending.question, systemImage: "questionmark.bubble").font(.headline)
            HStack {
                TextField("Your answer", text: $answer).textFieldStyle(.roundedBorder).onSubmit { pending.resume(answer) }
                Button("Reply") { pending.resume(answer) }.buttonStyle(.borderedProminent).disabled(answer.isEmpty)
                Button("Skip") { pending.resume(nil) }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatusBar: View {
    let controller: SessionController
    var body: some View {
        if controller.running || !controller.status.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(controller.status.isEmpty ? "Working" : controller.status).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let s = controller.startedAt {
                    TimelineView(.periodic(from: s, by: 1)) { ctx in
                        Text("\(Int(ctx.date.timeIntervalSince(s)))s").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button("Stop") { controller.stop() }.keyboardShortcut(".", modifiers: .command).controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 6)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
