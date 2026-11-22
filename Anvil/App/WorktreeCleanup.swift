import Foundation

/// A session worktree on disk that Worktree cleanup can remove, with what removing it would cost.
nonisolated struct WorktreeCandidate: Identifiable, Equatable, Sendable {
    var path: String
    var branch: String
    /// Sessions whose agent works in this folder.
    var sessionIDs: [UUID]
    var title: String
    /// Every commit on the branch is already in the project's checkout.
    var merged: Bool
    /// Commits only this branch has.
    var ahead: Int
    /// Uncommitted files in the worktree.
    var dirty: Int
    /// A session in it is working right now.
    var busy: Bool

    var id: String { path }
    /// Nothing would be lost by removing it.
    var safe: Bool { merged && dirty == 0 && !busy }

    var status: String {
        if busy { return "a session is running in it" }
        var parts: [String] = []
        parts.append(merged ? "merged" : "not merged (\(ahead) commit\(ahead == 1 ? "" : "s") only on this branch)")
        if dirty > 0 { parts.append("\(dirty) uncommitted file\(dirty == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    /// Worktrees Anvil makes live in `.anvil-worktrees` next to the project, on `anvil/` branches.
    static func isAnvilWorktree(_ w: Git.Worktree) -> Bool {
        w.path.contains("/.anvil-worktrees/") && (w.branch?.hasPrefix("anvil/") ?? false)
    }

    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
}

extension AppState {
    /// Anvil's worktrees for this project and whether each is safe to remove. `project` must be a git repository.
    func scanWorktrees() async -> [WorktreeCandidate] {
        guard let project else { return [] }
        let all = await Git.worktrees(project)
        var out: [WorktreeCandidate] = []
        for w in all where WorktreeCandidate.isAnvilWorktree(w) {
            guard let branch = w.branch else { continue }
            let key = WorktreeCandidate.canonical(w.path)
            let owners = sessions.filter { $0.workdir.map(WorktreeCandidate.canonical) == key }
            let busy = owners.contains { controller(for: $0.id)?.running ?? false }
            async let merged = Git.isMerged(project, branch: branch)
            async let ahead = Git.commitsAhead(project, branch: branch)
            async let status = Git.status(URL(fileURLWithPath: w.path))
            let title = owners.first.map { $0.title } ?? branch
            out.append(WorktreeCandidate(path: w.path, branch: branch, sessionIDs: owners.map(\.id), title: title,
                                         merged: await merged, ahead: await ahead, dirty: await status.files.count, busy: busy))
        }
        // Safe ones first, so the list reads as "these are done".
        return out.sorted { ($0.safe ? 0 : 1, $0.title) < ($1.safe ? 0 : 1, $1.title) }
    }

    /// Removes the worktree folders and branches. Uncommitted files and unmerged commits in what you pass are discarded,
    /// so only pass those the owner chose. Returns one line per worktree saying what happened.
    @discardableResult
    func removeWorktrees(_ items: [WorktreeCandidate]) async -> [String] {
        guard let project else { return [] }
        var report: [String] = []
        var removedSessions = Set<UUID>()
        for w in items {
            if w.busy { report.append("\(w.branch): skipped, a session is running in it"); continue }
            let r = await Git.removeWorktree(project, path: w.path, force: w.dirty > 0)
            if r.status != 0 && FileManager.default.fileExists(atPath: w.path) {
                report.append("\(w.branch): \(Fmt.line(r.combined, 160))"); continue
            }
            let b = await Git.deleteBranch(project, branch: w.branch, force: !w.merged)
            report.append(b.status == 0 ? "\(w.branch): removed" : "\(w.branch): folder removed, branch kept (\(Fmt.line(b.combined, 120)))")
            for id in w.sessionIDs {
                removedSessions.insert(id)
                if let c = controller(for: id) { c.session.worktreeRemoved = true; c.saveNow() }
                else if var s = SessionStore.load(id, root: project) { s.worktreeRemoved = true; try? SessionStore.save(s) }
            }
            for i in subSessions.indices where w.sessionIDs.contains(subSessions[i].id) && subSessions[i].state != .merged {
                subSessions[i].state = .failed
                subSessions[i].report += (subSessions[i].report.isEmpty ? "" : "\n") + "Worktree removed without merging."
            }
        }
        await Git.pruneWorktrees(project)
        refreshSessions()
        if let cur = current?.session.id, removedSessions.contains(cur) {
            if let next = sessions.first(where: { !$0.worktreeRemoved }) { select(next.id) } else { newSession() }
        }
        refreshGit()
        return report
    }
}
