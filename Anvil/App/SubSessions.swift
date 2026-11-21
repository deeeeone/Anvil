import Foundation

/// A session another session's agent started to do one part of a bigger change. It works in its own
/// git worktree on its own branch, runs in the background like a queue task, reports back when it
/// finishes, and the parent merges its branch. The owner can open any sub-session and steer it.
nonisolated struct SubSession: Identifiable, Equatable, Sendable {
    enum State: String, Sendable { case waiting, running, finished, failed, merged }
    var id: UUID              // the sub-session's session id
    var parentID: UUID
    var name: String
    var task: String
    var branch = ""
    var base = ""
    var dir = ""
    var state = State.waiting
    /// The latest finished request's report (what changed, how it was verified).
    var report = ""
    /// Messages the sub-session sent its parent that the parent hasn't collected yet.
    var inbox: [String] = []
    /// The parent has collected the latest report.
    var reportCollected = false
}

extension AppState {
    var runningSubSessions: Int { subSessions.filter { $0.state == .running }.count }

    func subSessions(of parent: UUID) -> [SubSession] { subSessions.filter { $0.parentID == parent } }

    fileprivate func sub(_ parent: UUID, named name: String) -> Int? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        return subSessions.firstIndex { $0.parentID == parent && ($0.name.lowercased() == key || $0.branch.lowercased() == key) }
    }

    /// Starts a sub-session for `parent` (or queues it until a slot frees up).
    fileprivate func spawnSubSession(parent: SessionController, name: String, task: String, model: String?) async -> Result<SubSession, ToolFailure> {
        guard let project else { return .failure(ToolFailure("no project is open")) }
        let pid = parent.session.id
        let clean = SkillLibrary.slug(name).prefix(24)
        guard !clean.isEmpty else { return .failure(ToolFailure("give the sub-session a short name")) }
        if sub(pid, named: String(clean)) != nil { return .failure(ToolFailure("a sub-session named \(clean) already exists; pick another name or message_session it")) }
        switch await Git.addWorktree(parent.root, name: String(clean)) {
        case .failure(let e):
            return .failure((e as? ToolFailure) ?? ToolFailure(e.localizedDescription))
        case .success(let (dir, branch, base)):
            var s = Session(projectPath: project.path)
            s.workdir = dir.path
            s.branch = branch
            s.baseBranch = base
            s.parentID = pid
            s.subName = String(clean)
            s.title = "↳ \(clean): \(Session.title(from: task))"
            s.mode = AppSettings.shared.queueMode
            s.model = model ?? parent.session.model
            let c = SessionController(session: s, root: dir, processes: processes)
            c.app = self
            registerController(c)
            let info = SubSession(id: s.id, parentID: pid, name: String(clean), task: task, branch: branch, base: base, dir: dir.path)
            subSessions.append(info)
            c.onFinish = { [weak self, weak c] outcome in
                guard let self, let c else { return }
                Task { await self.subSessionFinished(c, outcome: outcome) }
            }
            c.saveNow()
            refreshSessions()
            startWaitingSubSessions()
            return .success(subSessions.first { $0.id == s.id } ?? info)
        }
    }

    /// Starts waiting sub-sessions while there's room under the parallel limit (they go before the queue).
    func startWaitingSubSessions() {
        while backgroundRunning < AppSettings.shared.parallelTasks,
              let i = subSessions.firstIndex(where: { $0.state == .waiting }),
              let c = controller(for: subSessions[i].id) {
            subSessions[i].state = .running
            c.start(goal: Self.subSessionBrief(subSessions[i]), display: subSessions[i].task)
        }
    }

    static func subSessionBrief(_ s: SubSession) -> String {
        """
        You are a sub-session: another Anvil session (the main session) split a larger change and gave you one part of it. \
        You work in your own git worktree on branch \(s.branch), started from \(s.base). The main session merges your branch when you're done, \
        so stay inside your part: don't reformat or rename things other parts may touch, and don't edit shared files unless your task needs it.
        If something blocks you or the main session must know (an interface has to change, the task is unclear), use message_parent and keep going \
        on what you can. Verify your work (build or tests) before finishing. Anvil commits your changes on your branch.
        Finish with done:true and a short report in say: what you changed (files), how you verified it, and anything the main session must do when merging.

        YOUR TASK (\(s.name)):
        \(s.task)
        """
    }

    fileprivate func subSessionFinished(_ c: SessionController, outcome: AgentOutcome) async {
        guard let i = subSessions.firstIndex(where: { $0.id == c.session.id }) else { return }
        let dir = URL(fileURLWithPath: subSessions[i].dir)
        var report = outcome.text
        let st = await Git.status(dir)
        if !st.files.isEmpty {
            _ = await Git.stageAll(dir)
            let r = await Git.commit(dir, message: "Anvil sub-session \(subSessions[i].name): \(Fmt.line(subSessions[i].task, 60))\n\n\(Fmt.line(outcome.text, 400))")
            if r.status != 0 { report += "\n(commit failed: \(Fmt.line(r.combined, 160)))" }
        }
        guard let j = subSessions.firstIndex(where: { $0.id == c.session.id }) else { return }
        let files = await Git.changedFiles(dir, base: subSessions[j].base, branch: subSessions[j].branch)
        if !files.isEmpty { report += "\nFiles changed on \(subSessions[j].branch): \(files.prefix(30).joined(separator: ", "))\(files.count > 30 ? " (+\(files.count - 30) more)" : "")" }
        if let v = outcome.verifiedBy { report += "\nVerified by Anvil: `\(v)` passed." }
        subSessions[j].report = report
        subSessions[j].reportCollected = false
        if subSessions[j].state != .merged { subSessions[j].state = outcome.ok ? .finished : .failed }
        c.saveNow()
        let s = subSessions[j]
        if let parent = controller(for: s.parentID), !parent.running {
            parent.append(ChatItem(kind: .system, text: "Sub-session \(s.name) \(outcome.ok ? "finished" : "stopped") on \(s.branch): \(Fmt.line(outcome.text, 240))"))
        }
        Notifier.shared.post(id: s.id.uuidString, title: "Sub-session \(s.name) \(outcome.ok ? "finished" : "stopped")", body: Fmt.line(outcome.text, 120),
                             category: "done", session: s.id.uuidString)
        refreshSessions()
        startWaitingSubSessions()
        processQueue()
    }

    fileprivate func line(_ s: SubSession, controller c: SessionController?) -> String {
        var state = s.state.rawValue
        if s.state == .running, let c {
            if c.pendingPermission != nil { state = "running, WAITING FOR THE OWNER'S APPROVAL" }
            else if c.pendingQuestion != nil { state = "running, waiting for the owner to answer a question" }
            else if !c.status.isEmpty { state = "running (\(Fmt.line(c.status, 60)))" }
        }
        return "- \(s.name) [\(state)] branch \(s.branch)"
    }

    /// The agent tools a session gets: parents can start, wait for, message and merge sub-sessions;
    /// sub-sessions can message their parent.
    func subSessionTools(for c: SessionController) -> [ToolSpec] {
        if c.session.parentID != nil {
            return [ToolSpec(name: "message_parent", kind: .meta, signature: #"{"text": str}"#,
                             summary: "send the main session that started you a message (a blocking question, or something it must know before merging); it gets it with wait_sessions",
                             group: .work) { [weak self, weak c] a, _ in
                guard let self, let c, let pid = c.session.parentID else { return .fail("no parent session") }
                guard let text = a["text"]?.string ?? a["message"]?.string, !text.isEmpty else { return .fail("missing text") }
                guard let i = self.subSessions.firstIndex(where: { $0.id == c.session.id }) else { return .fail("the parent session isn't open anymore") }
                self.subSessions[i].inbox.append(text)
                if let parent = self.controller(for: pid), !parent.running {
                    parent.append(ChatItem(kind: .system, text: "Sub-session \(self.subSessions[i].name) says: \(Fmt.line(text, 400))"))
                }
                return .ok("sent to the main session")
            }]
        }

        let spawn = ToolSpec(name: "spawn_session", kind: .exec,
                             signature: #"{"name": str, "task": str, optional "model": str}"#,
                             summary: "start a sub-session: another agent working on one independent part of the change in its own git worktree and branch, in the background. It starts from your branch's LAST COMMIT, so commit shared groundwork (types, interfaces) first. Returns at once; collect results with wait_sessions, then merge_session",
                             group: .work,
                             command: { a in "anvil spawn_session \(a["name"]?.string ?? "")" }) { [weak self, weak c] a, _ in
            guard let self, let c else { return .fail("unavailable") }
            guard let name = a["name"]?.string, !name.isEmpty, let task = a["task"]?.string ?? a["brief"]?.string, !task.isEmpty else {
                return .fail("need name and task")
            }
            let dirty = await Git.status(c.root).files.count
            let head = await Git.head(c.root)
            switch await self.spawnSubSession(parent: c, name: name, task: task, model: a["model"]?.string) {
            case .failure(let e): return .fail(e.message)
            case .success(let s):
                var out = "started sub-session \(s.name) on branch \(s.branch) from \(s.base) @ \(head)"
                out += s.state == .waiting ? " (waiting for a free slot: \(AppSettings.shared.parallelTasks) run at once)" : ""
                if dirty > 0 { out += ". NOTE: you have \(dirty) uncommitted change(s); the sub-session does NOT see them" }
                return .ok(out + ". Call wait_sessions to collect its report.")
            }
        }

        let wait = ToolSpec(name: "wait_sessions", kind: .meta,
                            signature: #"{optional "names": [str], optional "timeout": seconds}"#,
                            summary: "wait until your sub-sessions (all, or the named ones) finish or one sends you a message, then return their reports and messages (default timeout 900s)",
                            group: .work) { [weak self, weak c] a, _ in
            guard let self, let c else { return .fail("unavailable") }
            let pid = c.session.id
            let names = Set((a["names"]?.array?.compactMap(\.string) ?? (a["name"]?.string).map { [$0] } ?? []).map { $0.lowercased() })
            func watched() -> [SubSession] {
                self.subSessions(of: pid).filter { names.isEmpty || names.contains($0.name.lowercased()) || names.contains($0.branch.lowercased()) }
            }
            if watched().isEmpty { return .fail(names.isEmpty ? "you have no sub-sessions; start one with spawn_session" : "no sub-session named \(names.sorted().joined(separator: ", "))") }
            let timeout = min(3600, max(10, Double(a["timeout"]?.int ?? 900)))
            let start = Date()
            c.agentStatus("Waiting for \(watched().filter { $0.state == .running || $0.state == .waiting }.map(\.name).joined(separator: ", "))")
            while Date().timeIntervalSince(start) < timeout {
                let list = watched()
                if list.contains(where: { !$0.inbox.isEmpty }) { break }
                if !list.contains(where: { $0.state == .running || $0.state == .waiting }) { break }
                do { try await Task.sleep(for: .seconds(1)) } catch { return .fail("stopped by the owner") }
            }
            var out: [String] = []
            for s in watched() {
                guard let i = self.subSessions.firstIndex(where: { $0.id == s.id }) else { continue }
                out.append(self.line(s, controller: self.controller(for: s.id)))
                for m in s.inbox { out.append("  MESSAGE from \(s.name): \(m)") }
                self.subSessions[i].inbox = []
                if (s.state == .finished || s.state == .failed) && !s.reportCollected {
                    out.append("  REPORT:\n" + Fmt.clip(s.report, max: 4000).split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))
                    self.subSessions[i].reportCollected = true
                }
            }
            let still = watched().filter { $0.state == .running || $0.state == .waiting }
            if !still.isEmpty && Date().timeIntervalSince(start) >= timeout { out.append("(timed out; still running: \(still.map(\.name).joined(separator: ", ")))") }
            out.append("Next: answer messages with message_session, then merge_session each finished branch (run the tests after each merge).")
            return .ok(out.joined(separator: "\n"))
        }

        let message = ToolSpec(name: "message_session", kind: .meta, signature: #"{"name": str, "text": str}"#,
                               summary: "send one of your sub-sessions a message: an answer, a correction, or a follow-up task (it reaches a running sub-session with its next step, or starts a new request)",
                               group: .work) { [weak self, weak c] a, _ in
            guard let self, let c else { return .fail("unavailable") }
            guard let name = a["name"]?.string, let text = a["text"]?.string ?? a["message"]?.string, !text.isEmpty else { return .fail("need name and text") }
            guard let i = self.sub(c.session.id, named: name), let child = self.controller(for: self.subSessions[i].id) else { return .fail("no sub-session named \(name)") }
            if self.subSessions[i].state == .merged { return .fail("\(name) was already merged; spawn a new sub-session for more work") }
            if self.subSessions[i].state == .waiting { self.subSessions[i].task += "\n\nAlso: \(text)"; return .ok("added to \(name)'s task (it hasn't started yet)") }
            if !child.running { self.subSessions[i].state = .running; self.subSessions[i].reportCollected = false }
            child.deliver(text, from: "the main session")
            return .ok("delivered to \(name)")
        }

        let merge = ToolSpec(name: "merge_session", kind: .exec,
                             signature: #"{"name": str, optional "resolve": bool}"#,
                             summary: "merge a finished sub-session's branch into your branch. Refuses when it would conflict (lists the files); with resolve:true it merges anyway and leaves conflict markers for you to fix and commit",
                             group: .work,
                             command: { [weak self, weak c] a in
                                 let branch = c.flatMap { c in self?.sub(c.session.id, named: a["name"]?.string ?? "").map { self?.subSessions[$0].branch ?? "" } } ?? ""
                                 return "git merge --no-ff \(branch.isEmpty ? (a["name"]?.string ?? "") : branch)"
                             }) { [weak self, weak c] a, ctx in
            guard let self, let c else { return .fail("unavailable") }
            guard let name = a["name"]?.string, let i = self.sub(c.session.id, named: name) else { return .fail("no sub-session named \(a["name"]?.string ?? "")") }
            let s = self.subSessions[i]
            if s.state == .running || s.state == .waiting { return .fail("\(s.name) is still working; wait_sessions first") }
            if s.state == .merged { return .ok("\(s.name) is already merged") }
            // Anything the sub-session left uncommitted goes on its branch first.
            let dir = URL(fileURLWithPath: s.dir)
            if !(await Git.status(dir).files.isEmpty) {
                _ = await Git.stageAll(dir)
                _ = await Git.commit(dir, message: "Anvil sub-session \(s.name): remaining changes")
            }
            let mine = await Git.status(c.root)
            if !mine.files.isEmpty { return .fail("commit or discard your own \(mine.files.count) uncommitted change(s) first, so the merge stays one clean unit") }
            let resolve = a["resolve"]?.bool ?? false
            if let conflicts = await Git.mergeConflicts(c.root, branch: s.branch), !conflicts.isEmpty, !resolve {
                return .fail("merging \(s.branch) would conflict in: \(conflicts.joined(separator: ", ")). Read both sides, then call merge_session with resolve:true and fix the markers, or message_session \(s.name) to rebase its work.")
            }
            let r = await Git.mergeBranch(c.root, branch: s.branch, message: "Merge sub-session \(s.name): \(Fmt.line(s.task, 60))")
            FileIndex.of(ctx.root).invalidate()
            self.refreshGit()
            if r.status != 0 {
                let conflicted = await Git.status(c.root).files.filter { $0.index == "U" || $0.worktree == "U" || ($0.index == "A" && $0.worktree == "A") }.map(\.path)
                if conflicted.isEmpty { return .fail("git merge failed: \(Fmt.line(r.combined, 400))") }
                return .ok("merge of \(s.branch) stopped on conflicts in: \(conflicted.joined(separator: ", ")). Fix the <<<<<<< ======= >>>>>>> markers in those files, then run: git add -A && git commit --no-edit")
            }
            if let j = self.subSessions.firstIndex(where: { $0.id == s.id }) { self.subSessions[j].state = .merged }
            let files = await Git.changedFiles(c.root, base: "HEAD^1", branch: "HEAD").count
            return .ok("merged \(s.branch) into your branch (\(files) file(s)). Run the tests before merging the next one.")
        }

        let list = ToolSpec(name: "list_sessions", kind: .meta, signature: "{}",
                            summary: "your sub-sessions with their state and branch",
                            group: .work) { [weak self, weak c] _, _ in
            guard let self, let c else { return .fail("unavailable") }
            let mine = self.subSessions(of: c.session.id)
            if mine.isEmpty { return .ok("no sub-sessions yet") }
            return .ok(mine.map { s in
                self.line(s, controller: self.controller(for: s.id)) + (s.inbox.isEmpty ? "" : " (\(s.inbox.count) unread message(s): wait_sessions collects them)")
            }.joined(separator: "\n"))
        }

        return [spawn, wait, message, merge, list]
    }
}
