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
    let controller: SessionController
    static let column: CGFloat = 760

    var body: some View {
        if controller.session.items.isEmpty && !controller.running {
            EmptySessionView(controller: controller)
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            let segments = Segment.build(controller.session.items)
                            ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                                switch seg {
                                case .item(let item): ItemView(item: item, controller: controller)
                                case .work(let items): WorkGroup(items: items, live: controller.running && idx == segments.count - 1)
                                }
                            }
                            Color.clear.frame(height: 8).id("bottom")
                        }
                        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 12)
                        .frame(maxWidth: Self.column + 56)
                        .frame(maxWidth: .infinity)
                        .environment(\.anvilSend, controller.running ? nil : { controller.send($0) })
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: controller.session.items.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: controller.pendingPermission?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                VStack(spacing: 10) {
                    if let p = controller.pendingPermission { PermissionCard(pending: p) }
                    if let q = controller.pendingQuestion { QuestionCard(pending: q) }
                    StatusLine(controller: controller)
                    Composer(controller: controller)
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
                .frame(maxWidth: Self.column + 80)
                .frame(maxWidth: .infinity)
                .background(alignment: .top) {
                    LinearGradient(colors: [Theme.window.opacity(0), Theme.window], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28).offset(y: -28).allowsHitTesting(false)
                }
            }
        }
    }
}

struct EmptySessionView: View {
    let controller: SessionController
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 40)
                Image("Logo").resizable().scaledToFit().frame(width: 56, height: 56)
                Text("What are we building in \(controller.root.lastPathComponent)?")
                    .font(.system(size: 26, weight: .semibold)).multilineTextAlignment(.center)
                Composer(controller: controller, prominent: true)
                FlowChips(items: ["Explain this codebase", "Find and fix failing tests", "/init"]) { controller.send($0) }
                if ProjectContext.memory(controller.root).isEmpty {
                    Text("Tip: /init writes an AGENTS.md so every session starts with the project's commands and conventions.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                }
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.center)
    }
}

/// Suggestion chips that wrap onto new lines when the window is narrow.
struct FlowChips: View {
    let items: [String]
    let tap: (String) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chips }
            VStack(spacing: 8) { chips }
        }
    }
    @ViewBuilder var chips: some View {
        ForEach(items, id: \.self) { s in
            Button(s) { tap(s) }.buttonStyle(Pill(kind: .ghost))
        }
    }
}

struct ItemView: View {
    let item: ChatItem
    let controller: SessionController

    var body: some View {
        switch item.kind {
        case .user:
            HStack(alignment: .top) {
                Spacer(minLength: 48)
                if !controller.running && item.historyIndex != nil {
                    RewindButton(item: item, controller: controller)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.text).font(.system(size: 14)).textSelection(.enabled).lineSpacing(2)
                    if item.images > 0 { Label("\(item.images) image\(item.images == 1 ? "" : "s")", systemImage: "photo").font(.caption).foregroundStyle(Theme.text3) }
                }
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(text: item.text).textSelection(.enabled)
                if item.final && item.skillWorthy && !controller.running {
                    Button { controller.saveSkill(from: item.id) } label: { Label("Save as skill", systemImage: "wand.and.stars") }
                        .buttonStyle(Pill(kind: .ghost, compact: true))
                        .help("Turn what the agent did here into a reusable SKILL.md for this project")
                }
            }
        case .suggestion:
            if let sug = item.suggestion { SuggestionCard(item: item, suggestion: sug, controller: controller) }
        case .plan:
            if let plan = item.plan { PlanCardView(plan: plan, itemID: item.id, controller: controller) }
        case .system:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Theme.text3)
                Text(item.text).font(.system(size: 12.5)).foregroundStyle(Theme.text2).textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(12, fill: Theme.surface.opacity(0.6))
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                Text(item.text).font(.system(size: 13)).textSelection(.enabled)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .card(12, fill: Theme.amber.opacity(0.08), stroke: Theme.amber.opacity(0.25))
        case .thought, .tool:
            WorkGroup(items: [item], live: false)
        }
    }
}

/// The agent's work, in the spirit of Claude Code's transcript: a dot per action, a one-line result under it.
struct WorkGroup: View {
    let items: [ChatItem]
    let live: Bool
    @State private var expanded: Bool?

    private var tools: [ToolStep] { items.compactMap(\.tool) }
    private var collapsible: Bool { tools.count > 3 && !live }
    private var isExpanded: Bool { expanded ?? !collapsible }

    var summary: String {
        var reads = 0, edits = 0, cmds = 0, searches = 0
        for t in tools {
            switch t.name {
            case "read_file", "list_dir": reads += 1
            case "edit_file", "multi_edit", "write_file", "delete_file": edits += 1
            case "shell", "start_process": cmds += 1
            case "grep", "glob", "web_search", "fetch_url": searches += 1
            default: break
            }
        }
        var parts: [String] = []
        if reads > 0 { parts.append("read \(reads) file\(reads == 1 ? "" : "s")") }
        if searches > 0 { parts.append("searched \(searches)×") }
        if edits > 0 { parts.append("edited \(edits)") }
        if cmds > 0 { parts.append("ran \(cmds) command\(cmds == 1 ? "" : "s")") }
        let text = parts.isEmpty ? "\(tools.count) steps" : parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if collapsible {
                Button { withAnimation(.snappy(duration: 0.2)) { expanded = !isExpanded } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(summary).font(.system(size: 12.5, weight: .medium))
                        let failed = tools.filter { $0.status == .failed || $0.status == .denied }.count
                        if failed > 0 { Text("\(failed) failed").font(.system(size: 11.5)).foregroundStyle(Theme.red.opacity(0.8)) }
                    }
                    .foregroundStyle(Theme.text3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(items) { i in
                        switch i.kind {
                        case .tool: ToolLine(item: i)
                        case .thought:
                            Text(i.text).font(.system(size: 12.5)).italic().foregroundStyle(Theme.text3).lineLimit(3).textSelection(.enabled)
                        default:
                            Text(i.text).font(.system(size: 13.5)).foregroundStyle(Theme.text2).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

struct ToolLine: View {
    @Environment(AppState.self) private var app
    let item: ChatItem
    @State private var open = false

    /// "Read", "src/a.swift" from the step summary ("$ npm test" becomes "Run", "npm test").
    var parts: (verb: String, target: String) {
        let s = item.tool?.summary ?? item.text
        if s.hasPrefix("$ ") { return ("Run", String(s.dropFirst(2))) }
        guard let sp = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<sp]), String(s[s.index(after: sp)...]))
    }

    var preview: String? {
        guard let t = item.tool else { return nil }
        switch t.status {
        case .running: return nil
        case .denied: return "Declined"
        case .failed: return t.output.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { Fmt.line(String($0), 160) }
        case .ok:
            if !t.diffs.isEmpty {
                return t.diffs.map { d in d.isNew ? "Created \(d.path), \(d.added) lines" : d.isDeleted ? "Deleted \(d.path)" : "\(d.path): added \(d.added), removed \(d.removed)" }.joined(separator: " · ")
            }
            if t.name == "shell" {
                let lines = t.output.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let first = lines.first ?? ""
                let last = lines.dropFirst().last.map { Fmt.line($0, 120) } ?? ""
                return last.isEmpty ? first : "\(first) · \(last)"
            }
            if t.name == "read_file" { return nil }
            let first = t.output.split(separator: "\n").first.map(String.init) ?? ""
            return first.isEmpty ? nil : Fmt.line(first, 140)
        }
    }

    var dot: Color {
        switch item.tool?.status ?? .ok {
        case .running: return Theme.accent
        case .ok: return Theme.green
        case .failed: return Theme.red
        case .denied: return Theme.amber
        }
    }

    var body: some View {
        if let t = item.tool {
            VStack(alignment: .leading, spacing: 5) {
                Button { withAnimation(.snappy(duration: 0.18)) { open.toggle() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Group {
                            if t.status == .running { Spinner().scaleEffect(0.75) }
                            else { Circle().fill(dot).frame(width: 7, height: 7) }
                        }
                        .frame(width: 12)
                        (Text(parts.verb).fontWeight(.semibold).foregroundColor(Theme.text)
                         + Text(parts.target.isEmpty ? "" : "  " + parts.target).font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.text2))
                            .font(.system(size: 13))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 6)
                        if let d = t.duration, d >= 2 { Text(String(format: "%.0fs", d)).font(.system(size: 11)).foregroundStyle(Theme.text3) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let p = preview {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("⎿").foregroundStyle(Theme.text3)
                        Text(p).foregroundStyle(t.status == .failed ? Theme.red.opacity(0.85) : Theme.text3).lineLimit(2)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.leading, 21)
                }
                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(t.diffs) { d in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(d.path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2)
                                    Spacer()
                                    Button("Open") { app.selectedDiff = d; app.previewFile = nil; app.inspectorTab = .changes; app.showInspector = true }
                                        .buttonStyle(Pill(kind: .ghost, compact: true))
                                }
                                DiffView(unified: d.unified, compact: true).frame(height: DiffView.height(d.unified, max: 320))
                            }
                        }
                        if !t.output.isEmpty && (t.diffs.isEmpty || t.status != .ok) {
                            ScrollView {
                                Text(t.output).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                            .frame(maxHeight: 280)
                            .card(12, fill: Theme.code)
                        }
                    }
                    .padding(.leading, 21)
                }
            }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(Theme.accent)
                Text("Plan").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(statusLabel).font(.system(size: 11.5, weight: .medium)).foregroundStyle(pending ? Theme.accent : Theme.text3)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, s in
                    let done = plan.done.contains(i + 1)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        ZStack {
                            Circle().stroke(done ? Theme.green : Theme.borderStrong, lineWidth: 1.5).frame(width: 18, height: 18)
                            if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.green) }
                            else { Text("\(i + 1)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text3) }
                        }
                        Text(s).font(.system(size: 13.5)).foregroundStyle(done ? Theme.text3 : Theme.text).strikethrough(done, color: Theme.text3)
                    }
                }
            }
            if pending, let p = controller.pendingPlan {
                TextField("Ask for changes (optional)", text: $revision, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .card(11, fill: Theme.surface2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { planButtons(p); Spacer(minLength: 6); cancel(p) }
                    VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { planButtons(p) }; cancel(p) }
                }
            }
        }
        .padding(18)
        .card(18, fill: Theme.surface, stroke: pending ? Theme.accent.opacity(0.5) : Theme.border)
    }

    var statusLabel: String {
        switch plan.state {
        case .pending: return pending ? "Waiting for you" : "Not approved"
        case .approved: return "\(plan.done.count) of \(plan.steps.count) done"
        case .revised: return "Revised"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder func planButtons(_ p: PendingPlan) -> some View {
        if !revision.trimmingCharacters(in: .whitespaces).isEmpty {
            Button("Revise plan") { p.resume(.revise(revision)) }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return)
        } else {
            Button("Approve") { p.resume(.approve) }.buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return)
            Button("Approve, auto-accept edits") { p.resume(.approveAutoEdits) }.buttonStyle(Pill(kind: .secondary))
        }
    }

    func cancel(_ p: PendingPlan) -> some View {
        Button("Cancel") { p.resume(.cancel) }.buttonStyle(Pill(kind: .ghost))
    }
}

struct PermissionCard: View {
    let pending: PendingPermission
    @State private var note = ""

    var body: some View {
        let r = pending.request
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: r.command != nil ? "terminal" : "pencil")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title(r)).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 6)
                if r.reason != "edit" && r.reason != "run command" {
                    Label(r.reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.amber).lineLimit(2)
                }
            }
            if let cmd = r.command {
                Text(cmd).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled).lineLimit(8)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .card(11, fill: Theme.code)
            }
            ForEach(r.diffs.prefix(4)) { d in
                if r.diffs.count > 1 { Text("\(d.path)  \(d.statLabel)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text3) }
                DiffView(unified: d.unified, compact: true)
                    .frame(height: DiffView.height(d.unified, max: r.diffs.count > 1 ? 140 : 260))
            }
            if r.diffs.count > 4 { Text("and \(r.diffs.count - 4) more files").font(.system(size: 11.5)).foregroundStyle(Theme.text3) }
            TextField("Or tell the agent what to do instead", text: $note)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .card(10, fill: Theme.surface2)
                .onSubmit { if !note.isEmpty { pending.resume(.deny(note)) } }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { allow(r); Spacer(minLength: 6); decline }
                VStack(alignment: .leading, spacing: 8) { HStack(spacing: 8) { allow(r) }; decline }
            }
        }
        .padding(16)
        .card(18, fill: Theme.surface, stroke: Theme.accent.opacity(0.45))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    @ViewBuilder func allow(_ r: PermissionRequest) -> some View {
        Button { pending.resume(.allow) } label: { Text("Allow") + Text("  ⏎").foregroundColor(.white.opacity(0.6)) }
            .buttonStyle(Pill(kind: .primary)).keyboardShortcut(.return, modifiers: [])
        if r.command != nil {
            if let key = r.commandKey, Permissions.dangerReason(r.command ?? "") == nil {
                Button("Always allow \u{201C}\(Fmt.line(key, 28))\u{201D}") { pending.resume(.allowSession) }
                    .buttonStyle(Pill(kind: .secondary)).help("Allow this command for the rest of the session")
            }
        } else {
            if r.batchRemaining > 0 {
                Button("Allow all \(r.batchRemaining + 1) in this reply") { pending.resume(.allowBatch) }
                    .buttonStyle(Pill(kind: .secondary)).help("Approve this edit and the other edits the agent sent with it")
            }
            Button("Allow all edits") { pending.resume(.allowSession) }
                .buttonStyle(Pill(kind: r.batchRemaining > 0 ? .ghost : .secondary)).help("Switch this session to auto-accept edits")
        }
    }

    var decline: some View {
        Button { pending.resume(.deny(note.isEmpty ? nil : note)) } label: { Text("Decline") + Text("  esc").foregroundColor(Theme.text3) }
            .buttonStyle(Pill(kind: .ghost)).keyboardShortcut(.escape, modifiers: [])
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
        VStack(alignment: .leading, spacing: 10) {
            Label(pending.question, systemImage: "questionmark.bubble").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                TextField("Your answer", text: $answer).textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 8).card(10, fill: Theme.surface2)
                    .onSubmit { pending.resume(answer) }
                Button("Reply") { pending.resume(answer) }.buttonStyle(Pill(kind: .primary)).disabled(answer.isEmpty)
                Button("Skip") { pending.resume(nil) }.buttonStyle(Pill(kind: .ghost))
            }
        }
        .padding(16)
        .card(18, fill: Theme.surface, stroke: Theme.accent.opacity(0.45))
    }
}

/// "✻ Running npm test… 12s · esc to interrupt"
struct StatusLine: View {
    let controller: SessionController
    var body: some View {
        if controller.running {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Spinner()
                Text((controller.status.isEmpty ? "Working" : controller.status) + "…")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent.opacity(0.95))
                    .lineLimit(1).truncationMode(.middle)
                if let s = controller.startedAt {
                    TimelineView(.periodic(from: s, by: 1)) { ctx in
                        Text("\(Int(ctx.date.timeIntervalSince(s)))s").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.text3)
                    }
                }
                Text("· esc to interrupt").font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1).layoutPriority(-1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            if !controller.liveText.isEmpty {
                Text(controller.liveText).font(.system(size: 12.5)).italic().foregroundStyle(Theme.text3)
                    .lineLimit(2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 30).padding(.trailing, 6)
                    .transition(.opacity)
            }
          }
        }
    }
}


struct RewindButton: View {
    let item: ChatItem
    let controller: SessionController
    @State private var confirm = false
    @State private var hover = false

    var body: some View {
        Button { confirm = true } label: {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? Theme.text : Theme.text3).frame(width: 24, height: 24)
                .background(hover ? Theme.surface2 : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.top, 6)
        .help("Rewind to here: restore files to how they were before this message and edit it")
        .confirmationDialog("Rewind to before this message?", isPresented: $confirm) {
            Button("Rewind", role: .destructive) { controller.rewind(to: item.id) }
        } message: {
            Text(controller.canRewindConversation(item)
                 ? "Files the agent changed from this message on are restored, the conversation goes back to this point, and the message returns to the composer."
                 : "Files are restored, but the conversation was compacted after this point, so the agent starts fresh.")
        }
    }
}

struct SuggestionCard: View {
    let item: ChatItem
    let suggestion: Suggestion
    let controller: SessionController

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "lightbulb").foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 6) {
                Text("Remember this for the project?").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                Text(item.text).font(.system(size: 13.5))
                switch suggestion.state {
                case .open:
                    HStack(spacing: 8) {
                        Button("Add to AGENTS.md") { controller.acceptSuggestion(item.id) }.buttonStyle(Pill(kind: .secondary, compact: true))
                        Button("Dismiss") { controller.dismissSuggestion(item.id) }.buttonStyle(Pill(kind: .ghost, compact: true))
                    }
                case .accepted: Label("Saved", systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(Theme.green)
                case .dismissed: Text("Dismissed").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .card(14, fill: Theme.surface, stroke: Theme.amber.opacity(0.25))
    }
}
