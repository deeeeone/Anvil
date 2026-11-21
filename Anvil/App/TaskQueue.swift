import Foundation

/// A request waiting for (or done in) the background queue. Each runs in its own git worktree, one at a time.
nonisolated struct QueuedTask: Codable, Identifiable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case queued, running, done, failed, cancelled }
    var id = UUID()
    var prompt: String
    var state: State = .queued
    var sessionID: UUID?
    var branch: String?
    var summary: String?
    var created = Date()

    static func file(_ root: URL) -> URL {
        Paths.dir(Paths.sub("projects").appendingPathComponent(SessionStore.projectKey(root))).appendingPathComponent("queue.json")
    }
    static func load(_ root: URL) -> [QueuedTask] {
        guard let d = try? Data(contentsOf: file(root)) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        // A task that was running when Anvil quit didn't finish.
        return ((try? dec.decode([QueuedTask].self, from: d)) ?? []).map { var t = $0; if t.state == .running { t.state = .failed; t.summary = "Interrupted (Anvil quit)." }; return t }
    }
    static func save(_ list: [QueuedTask], root: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(list) { try? d.write(to: file(root), options: .atomic) }
    }
}

extension AppState {
    func enqueue(_ prompt: String) {
        guard let project else { return }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        queue.append(QueuedTask(prompt: p))
        QueuedTask.save(queue, root: project)
        processQueue()
    }

    func cancelQueued(_ id: UUID) {
        guard let project, let i = queue.firstIndex(where: { $0.id == id }) else { return }
        if queue[i].state == .running, let sid = queue[i].sessionID { controller(for: sid)?.stop() }
        if queue[i].state == .queued || queue[i].state == .running { queue[i].state = .cancelled }
        else { queue.remove(at: i) }
        QueuedTask.save(queue, root: project)
    }

    func clearFinishedQueue() {
        guard let project else { return }
        queue.removeAll { [.done, .failed, .cancelled].contains($0.state) }
        QueuedTask.save(queue, root: project)
    }

    /// Starts the next queued task when nothing in the queue is running.
    func processQueue() {
        guard let project, !queue.contains(where: { $0.state == .running }),
              let i = queue.firstIndex(where: { $0.state == .queued }) else { return }
        queue[i].state = .running
        QueuedTask.save(queue, root: project)
        let task = queue[i]
        Task {
            switch await Git.addWorktree(project, name: task.prompt) {
            case .failure(let e):
                finishQueued(task.id, state: .failed, summary: (e as? ToolFailure)?.message ?? e.localizedDescription)
            case .success(let (dir, branch, base)):
                var s = Session(projectPath: project.path)
                s.workdir = dir.path
                s.branch = branch
                s.baseBranch = base
                s.title = Session.title(from: task.prompt)
                s.mode = AppSettings.shared.queueMode
                let c = SessionController(session: s, root: dir, processes: processes)
                c.app = self
                registerController(c)
                if let j = queue.firstIndex(where: { $0.id == task.id }) { queue[j].sessionID = s.id; queue[j].branch = branch }
                c.onFinish = { [weak self, weak c] outcome in
                    guard let self, let c else { return }
                    Task {
                        // Commit the work on its branch so it's ready to review and merge.
                        let st = await Git.status(dir)
                        var summary = Fmt.line(outcome.text, 200)
                        if !st.files.isEmpty {
                            _ = await Git.stageAll(dir)
                            let r = await Git.commit(dir, message: "Anvil: \(Fmt.line(task.prompt, 60))\n\n\(Fmt.line(outcome.text, 400))")
                            if r.status != 0 { summary += " (commit failed: \(Fmt.line(r.combined, 120)))" }
                        } else if outcome.ok {
                            summary += " (no file changes)"
                        }
                        c.saveNow()
                        self.finishQueued(task.id, state: outcome.ok ? .done : .failed, summary: summary)
                    }
                }
                refreshSessions()
                c.start(goal: task.prompt, display: task.prompt)
            }
        }
    }

    func finishQueued(_ id: UUID, state: QueuedTask.State, summary: String) {
        guard let project, let i = queue.firstIndex(where: { $0.id == id }) else { return }
        if queue[i].state != .cancelled { queue[i].state = state }
        queue[i].summary = summary
        QueuedTask.save(queue, root: project)
        refreshSessions()
        Notifier.shared.post(id: id.uuidString, title: state == .done ? "Queue: done" : "Queue: stopped", body: "\(Fmt.line(queue[i].prompt, 80)): \(summary)",
                             category: "done", session: queue[i].sessionID?.uuidString ?? "")
        processQueue()
    }
}
