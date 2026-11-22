import SwiftUI

/// Lists the session worktrees on disk and removes the ones you pick, with their branches.
struct WorktreeCleanupView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var items: [WorktreeCandidate] = []
    @State private var picked = Set<String>()
    @State private var loading = true
    @State private var working = false
    @State private var report: [String] = []
    @State private var confirm = false

    private var chosen: [WorktreeCandidate] { items.filter { picked.contains($0.id) && !$0.busy } }
    private var risky: [WorktreeCandidate] { chosen.filter { !$0.safe } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Clean up worktrees").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            Text("Removes each worktree's folder and its anvil/ branch. Merged ones are safe; the conversation stays in the sidebar as history.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.text2)

            if loading {
                HStack { Spinner(); Text("Looking at your worktrees…").foregroundStyle(Theme.text2) }.padding(.vertical, 24)
            } else if items.isEmpty && report.isEmpty {
                Text("No Anvil worktrees to clean up.").foregroundStyle(Theme.text2).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(items) { w in row(w) }
                    }
                }
                .frame(maxHeight: 320)
            }

            if !report.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(report, id: \.self) { Text($0).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.text2) }
                }
            }

            HStack {
                Button("Select merged") { picked = Set(items.filter(\.safe).map(\.id)) }
                    .disabled(!items.contains(where: \.safe))
                Spacer()
                Button(role: risky.isEmpty ? nil : .destructive) {
                    if risky.isEmpty { run() } else { confirm = true }
                } label: {
                    Text(chosen.isEmpty ? "Remove" : "Remove \(chosen.count)")
                }
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Theme.window)
        .task { await reload(selectSafe: true) }
        .confirmationDialog("Discard work that isn't merged?", isPresented: $confirm) {
            Button("Remove and discard", role: .destructive) { run() }
        } message: {
            Text(risky.map { "\($0.branch): \($0.status)" }.joined(separator: "\n") + "\n\nThis cannot be undone.")
        }
    }

    private func row(_ w: WorktreeCandidate) -> some View {
        Button {
            guard !w.busy else { return }
            if picked.contains(w.id) { picked.remove(w.id) } else { picked.insert(w.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: picked.contains(w.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(picked.contains(w.id) ? Theme.accent : Theme.text3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(w.branch).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3).lineLimit(1)
                    Text(w.status).font(.system(size: 11.5)).foregroundStyle(w.safe ? Theme.green : (w.busy ? Theme.text3 : Theme.amber))
                }
                Spacer()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .opacity(w.busy ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(w.title), \(w.status)")
        .accessibilityAddTraits(picked.contains(w.id) ? .isSelected : [])
    }

    private func reload(selectSafe: Bool) async {
        loading = true
        items = await app.scanWorktrees()
        picked = selectSafe ? Set(items.filter(\.safe).map(\.id)) : picked.intersection(items.map(\.id))
        loading = false
    }

    private func run() {
        let todo = chosen
        working = true
        Task {
            report = await app.removeWorktrees(todo)
            await reload(selectSafe: false)
            working = false
        }
    }
}
