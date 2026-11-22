import XCTest
@testable import Anvil

/// Worktree cleanup, sub-session persistence and the sidebar tree, and token calibration with the context gauge.
final class CleanupTokensTreeTests: XCTestCase {
    // MARK: Worktree cleanup

    private func makeRepo() async throws -> (base: URL, repo: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-clean-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = await Git.run(["init", "-b", "main"], in: repo)
        _ = await Git.run(["config", "user.email", "t@example.com"], in: repo)
        _ = await Git.run(["config", "user.name", "T"], in: repo)
        try "v1\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(repo)
        _ = await Git.commit(repo, message: "init")
        return (base, repo)
    }

    func testParseWorktreesReadsPathsAndBranches() {
        let text = """
        worktree /Users/me/proj
        HEAD abc123
        branch refs/heads/main

        worktree /Users/me/.anvil-worktrees/proj-a1b2c3
        HEAD def456
        branch refs/heads/anvil/fix-a1b2c3

        worktree /Users/me/detached
        HEAD 999999
        detached
        """
        let list = Git.parseWorktrees(text)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].branch, "main")
        XCTAssertEqual(list[1].branch, "anvil/fix-a1b2c3")
        XCTAssertNil(list[2].branch)
        XCTAssertFalse(WorktreeCandidate.isAnvilWorktree(list[0]))
        XCTAssertTrue(WorktreeCandidate.isAnvilWorktree(list[1]))
        XCTAssertFalse(WorktreeCandidate.isAnvilWorktree(list[2]))
    }

    func testMergedWorktreeIsSafeAndRemovable() async throws {
        let (base, repo) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        guard case .success(let (dir, branch, _)) = await Git.addWorktree(repo, name: "done") else { return XCTFail("worktree") }

        // Nothing committed on the branch yet: trivially merged.
        let m0 = await Git.isMerged(repo, branch: branch)
        XCTAssertTrue(m0)

        try "v2\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(dir)
        _ = await Git.commit(dir, message: "work")
        let m1 = await Git.isMerged(repo, branch: branch)
        XCTAssertFalse(m1)
        let ahead = await Git.commitsAhead(repo, branch: branch)
        XCTAssertEqual(ahead, 1)

        // Plain branch delete refuses to lose the commit.
        let refused = await Git.deleteBranch(repo, branch: branch, force: false)
        XCTAssertNotEqual(refused.status, 0)

        let merge = await Git.mergeBranch(repo, branch: branch, message: "merge")
        XCTAssertEqual(merge.status, 0, merge.combined)
        let m2 = await Git.isMerged(repo, branch: branch)
        XCTAssertTrue(m2)

        let listed = await Git.worktrees(repo)
        XCTAssertTrue(listed.contains { $0.branch == branch })
        let rm = await Git.removeWorktree(repo, path: dir.path, force: false)
        XCTAssertEqual(rm.status, 0, rm.combined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        let del = await Git.deleteBranch(repo, branch: branch, force: false)
        XCTAssertEqual(del.status, 0, del.combined)
        let after = await Git.worktrees(repo)
        XCTAssertFalse(after.contains { $0.branch == branch })
    }

    func testDirtyWorktreeNeedsForceToRemove() async throws {
        let (base, repo) = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: base) }
        guard case .success(let (dir, _, _)) = await Git.addWorktree(repo, name: "wip") else { return XCTFail("worktree") }
        try "scratch\n".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let refused = await Git.removeWorktree(repo, path: dir.path, force: false)
        XCTAssertNotEqual(refused.status, 0, "uncommitted files must not be thrown away without force")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        let forced = await Git.removeWorktree(repo, path: dir.path, force: true)
        XCTAssertEqual(forced.status, 0, forced.combined)
    }

    func testCandidateStatusAndSafety() {
        var w = WorktreeCandidate(path: "/p", branch: "anvil/x", sessionIDs: [], title: "x", merged: true, ahead: 0, dirty: 0, busy: false)
        XCTAssertTrue(w.safe)
        XCTAssertEqual(w.status, "merged")
        w.merged = false; w.ahead = 2
        XCTAssertFalse(w.safe)
        XCTAssertTrue(w.status.contains("2 commits"))
        w.merged = true; w.dirty = 1
        XCTAssertFalse(w.safe)
        w.dirty = 0; w.busy = true
        XCTAssertFalse(w.safe)
    }

    func testRemovedWorktreeSessionRefusesToRun() async throws {
        var s = Session(projectPath: "/tmp/x")
        s.worktreeRemoved = true
        let c = SessionController(session: s, root: URL(fileURLWithPath: "/tmp/x"), processes: ProcessManager())
        var outcome: AgentOutcome?
        c.onFinish = { outcome = $0 }
        c.start(goal: "hi", display: "hi")
        XCTAssertFalse(c.running)
        XCTAssertEqual(outcome?.ok, false)
        XCTAssertTrue(c.session.items.contains { $0.kind == .error })
    }

    // MARK: Persistence

    func testSessionKeepsParentLinkAcrossSaveAndLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-sup-\(UUID().uuidString)")
        setenv("ANVIL_SUPPORT_DIR", dir.path, 1)
        defer { unsetenv("ANVIL_SUPPORT_DIR"); try? FileManager.default.removeItem(at: dir) }
        let root = URL(fileURLWithPath: "/tmp/anvil-proj-\(UUID().uuidString)")
        var s = Session(projectPath: root.path)
        let parent = UUID()
        s.parentID = parent
        s.subName = "api"
        s.worktreeRemoved = true
        s.usage.lastCached = 900
        try SessionStore.save(s)
        let back = try XCTUnwrap(SessionStore.load(s.id, root: root))
        XCTAssertEqual(back.parentID, parent)
        XCTAssertEqual(back.subName, "api")
        XCTAssertTrue(back.worktreeRemoved)
        XCTAssertEqual(back.usage.lastCached, 900)
        let summary = try XCTUnwrap(SessionStore.list(root: root).first)
        XCTAssertEqual(summary.parentID, parent)
        XCTAssertTrue(summary.worktreeRemoved)
    }

    func testSubSessionLinksSurviveARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-sup-\(UUID().uuidString)")
        setenv("ANVIL_SUPPORT_DIR", dir.path, 1)
        defer { unsetenv("ANVIL_SUPPORT_DIR"); try? FileManager.default.removeItem(at: dir) }
        let root = URL(fileURLWithPath: "/tmp/anvil-proj-\(UUID().uuidString)")
        let parent = UUID()
        func sub(_ name: String, _ state: SubSession.State) -> SubSession {
            SubSession(id: UUID(), parentID: parent, name: name, task: "do \(name)", branch: "anvil/\(name)-abc123", base: "main", dir: "/tmp/\(name)", state: state, report: "done", inbox: ["q"], reportCollected: true)
        }
        let list = [sub("api", .merged), sub("ui", .running), sub("db", .finished), sub("gone", .finished)]
        SubSession.save(list, root: root)
        let loaded = SubSession.load(root, sessionExists: { id in id != list[3].id })
        XCTAssertEqual(loaded.map(\.name), ["api", "ui", "db"], "a link whose session is gone is dropped")
        XCTAssertEqual(loaded[0].state, .merged)
        XCTAssertEqual(loaded[2].state, .finished)
        XCTAssertEqual(loaded[2].parentID, parent)
        XCTAssertEqual(loaded[1].state, .failed, "work that was running when Anvil quit did not finish")
        XCTAssertTrue(loaded[1].report.contains("Interrupted"))
        XCTAssertFalse(loaded[1].reportCollected)
    }

    // MARK: Sidebar tree

    private func summary(_ title: String, parent: UUID? = nil, id: UUID = UUID()) -> SessionSummary {
        SessionSummary(id: id, title: title, updated: Date(), cost: 0, parentID: parent)
    }

    func testSubSessionsNestUnderTheirParent() {
        let p = summary("Main")
        let a = summary("↳ api", parent: p.id), b = summary("↳ ui", parent: p.id)
        let other = summary("Other")
        let rows = SessionTree.rows([a, other, p, b])
        XCTAssertEqual(rows.map(\.summary.title), ["Other", "Main", "↳ api", "↳ ui"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 1])
        XCTAssertEqual(rows.first { $0.id == p.id }?.childCount, 2)
    }

    func testCollapsedParentHidesChildrenButKeepsCount() {
        let p = summary("Main")
        let a = summary("↳ api", parent: p.id)
        let rows = SessionTree.rows([p, a], collapsed: [p.id])
        XCTAssertEqual(rows.map(\.summary.title), ["Main"])
        XCTAssertEqual(rows[0].childCount, 1)
    }

    func testOrphanedChildAndCyclesStillShow() {
        let orphan = summary("↳ lost", parent: UUID())
        XCTAssertEqual(SessionTree.rows([orphan]).first?.depth, 0)
        let x = UUID(), y = UUID()
        let cyc = SessionTree.rows([summary("X", parent: y, id: x), summary("Y", parent: x, id: y)])
        XCTAssertEqual(Set(cyc.map(\.summary.title)), ["X", "Y"])
    }

    // MARK: Tokens

    func testCalibratorStartsAtDefaultAndLearnsFromProviderCounts() {
        let c = TokenCalibrator()
        XCTAssertEqual(c.ratio(for: "m"), 3.5)
        XCTAssertEqual(c.tokens(chars: 3500, model: "m"), 1000)
        c.learn(model: "m", chars: 20_000, tokens: 5_000)   // 4.0 chars per token
        XCTAssertEqual(c.ratio(for: "m"), 4.0, accuracy: 0.001)
        XCTAssertEqual(c.tokens(chars: 8000, model: "M"), 2000, "model ids are case-insensitive")
        c.learn(model: "m", chars: 12_000, tokens: 5_000)   // 2.4: moves the average, doesn't replace it
        XCTAssertEqual(c.ratio(for: "m"), 3.6, accuracy: 0.001)
        XCTAssertEqual(c.sampleCount(for: "m"), 2)
        XCTAssertEqual(c.ratio(for: "other"), 3.5)
    }

    func testCalibratorIgnoresTinyAndAbsurdSamples() {
        let c = TokenCalibrator()
        c.learn(model: "m", chars: 100, tokens: 50)
        c.learn(model: "m", chars: 5_000, tokens: 0)
        XCTAssertEqual(c.sampleCount(for: "m"), 0)
        c.learn(model: "m", chars: 400_000, tokens: 400)   // 1000 chars/token is a bad reading: clamped
        XCTAssertEqual(c.ratio(for: "m"), 8.0, accuracy: 0.001)
    }

    func testCalibratorPersistsToDisk() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("ratios-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: f) }
        let a = TokenCalibrator(file: f)
        a.learn(model: "m", chars: 10_000, tokens: 2_500)
        let b = TokenCalibrator(file: f)
        XCTAssertEqual(b.ratio(for: "m"), 4.0, accuracy: 0.001)
        XCTAssertEqual(b.sampleCount(for: "m"), 1)
    }

    func testEstimateUsesTheCalibratedRatio() {
        let c = TokenCalibrator()
        let msgs = [ChatMessage.user(String(repeating: "a", count: 7000))]
        XCTAssertEqual(Compactor.estimateTokens(msgs, calibrator: c), 2000)
        c.learn(model: "x", chars: 7000, tokens: 1000)
        XCTAssertEqual(Compactor.estimateTokens(msgs, model: "x", calibrator: c), 1000)
    }

    func testContextGaugeShowsFillAndCacheHits() {
        let g = ContextGauge(lastPrompt: 50_000, lastCached: 40_000, estimate: 48_000, window: 200_000)
        XCTAssertTrue(g.measured)
        XCTAssertEqual(g.fill, 0.25, accuracy: 0.0001)
        XCTAssertEqual(g.cachedFill, 0.2, accuracy: 0.0001)
        XCTAssertEqual(g.hitRate ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(g.label, "50k / 200k · 80% cached")
        XCTAssertFalse(g.nearlyFull)
        XCTAssertTrue(g.help.contains("80%"))
    }

    func testContextGaugeFallsBackToEstimateAndUnknownWindow() {
        let g = ContextGauge(lastPrompt: 0, lastCached: 0, estimate: 12_000, window: nil)
        XCTAssertFalse(g.measured)
        XCTAssertEqual(g.label, "~12k")
        XCTAssertEqual(g.fill, 0)
        XCTAssertNil(g.hitRate)
        let grown = ContextGauge(lastPrompt: 10_000, lastCached: 9_000, estimate: 30_000, window: 35_000)
        XCTAssertFalse(grown.measured, "the conversation grew since the last count")
        XCTAssertNil(grown.hitRate)
        XCTAssertTrue(grown.nearlyFull)
        XCTAssertEqual(ContextGauge(lastPrompt: 100, lastCached: 500, estimate: 0, window: 1000).cached, 100, "cache can't exceed the prompt")
    }
}
