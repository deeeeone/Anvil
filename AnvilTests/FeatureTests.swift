import XCTest
import WebKit
@testable import Anvil

final class MentionTests: XCTestCase {
    func testActiveQueryAndTokens() {
        XCTAssertEqual(Mentions.activeQuery("fix @src/pri"), "src/pri")
        XCTAssertEqual(Mentions.activeQuery("look at @"), "")
        XCTAssertNil(Mentions.activeQuery("mail me@example.com"), "an email address isn't a mention")
        XCTAssertNil(Mentions.activeQuery("@a.js and more"))
        XCTAssertEqual(Mentions.tokens(in: "compare @a.js with @lib/b.js. Also @git-diff"), ["a.js", "lib/b.js", "git-diff"])
    }

    func testSuggestionsRankFileNamesAndFolders() {
        let files = ["src/pricing.js", "src/cart.js", "test/pricing.test.js", "README.md"]
        let s = Mentions.suggestions("pri", files: files).map(\.token)
        XCTAssertEqual(s.first, "src/pricing.js")
        XCTAssertTrue(s.contains("test/pricing.test.js"))
        XCTAssertTrue(Mentions.suggestions("src", files: files).map(\.token).contains("src/"))
        XCTAssertEqual(Mentions.suggestions("git", files: files).first?.token, "git-diff")
    }

    func testExpandAttachesFilesAndFolders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-mention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "const x = 1\n".write(to: dir.appendingPathComponent("lib/a.js"), atomically: true, encoding: .utf8)
        let out = await Mentions.expand("why does @lib/a.js fail? see @lib/ and @last-output", root: dir, lastOutput: "Error: boom")
        XCTAssertTrue(out.contains("file lib/a.js (1 lines):\n1\tconst x = 1"), out)
        XCTAssertTrue(out.contains("folder lib/ contains: a.js"))
        XCTAssertTrue(out.contains("Error: boom"))
        let none = await Mentions.expand("no mentions here", root: dir, lastOutput: nil)
        XCTAssertEqual(none, "")
    }
}

final class LearningTests: XCTestCase {
    func testCorrectionHeuristic() {
        XCTAssertTrue(Conventions.looksLikeCorrection("no, don't use classes here, use plain functions"))
        XCTAssertTrue(Conventions.looksLikeCorrection("we use tabs not spaces in this project"))
        XCTAssertFalse(Conventions.looksLikeCorrection("now add a --verbose flag"))
    }

    func testConventionGoesUnderItsSection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-conv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Conventions.save("Use tabs for indentation.", root: dir)
        try Conventions.save("Prefer plain functions over classes.", root: dir)
        try Conventions.save("Use tabs for indentation.", root: dir)   // duplicate ignored
        let text = try String(contentsOf: dir.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "## Conventions").count, 2)
        XCTAssertTrue(text.contains("- Use tabs for indentation.\n- Prefer plain functions over classes."), text)
        XCTAssertEqual(text.components(separatedBy: "Use tabs").count, 2)
    }

    func testConventionKeepsLaterSections() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-conv2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# P\n\n## Conventions\n- One.\n\n## Testing\nRun make test.\n".write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try Conventions.save("Two.", root: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("- One.\n- Two.\n\n## Testing"), text)
    }

    func testSkillBuilderWritesSkillMD() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-skill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = JSON.parse(#"{"name": "Add CLI Flag", "description": "Adding a flag to the argparse CLI", "instructions": "1. Edit sortlines.py\n2. Run the tests"}"#)!
        let file = try SkillBuilder.save(json: json, root: dir)
        XCTAssertEqual(file.path, dir.appendingPathComponent(".anvil/skills/add-cli-flag/SKILL.md").path)
        XCTAssertEqual(SkillLibrary.find("add-cli-flag", project: dir)?.description, "Adding a flag to the argparse CLI")
    }
}

final class LimitAndRewindTests: XCTestCase {
    func testCostLimitStopsTheRequest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        var calls = 0
        brain.override = { [weak brain] _, _ in
            calls += 1
            brain?.onUsage?(ChatUsage(prompt: 1000, completion: 100, cost: 0.01), "m", 0.01)   // each turn costs a cent
            return "```json\n{\"actions\": [{\"tool\": \"list_dir\", \"args\": {}}]}\n```"
        }
        let agent = Agent(ctx: ToolContext(root: dir, processes: ProcessManager(), host: TestHost()), brain: brain)
        agent.autoVerify = false; agent.selfReview = false; agent.streaming = false; agent.prepareWhilePlanning = false; agent.memory = ProjectMemory()
        agent.maxCost = 0.025
        let out = await agent.run(goal: "loop")
        XCTAssertFalse(out.ok)
        XCTAssertTrue(out.text.contains("cost limit"), out.text)
        XCTAssertEqual(calls, 3)
    }

    func testRewindRestoresFilesAndCutsTheConversation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-rewind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "after".write(to: file, atomically: true, encoding: .utf8)
        var s = Session(projectPath: dir.path)
        let first = ChatItem(kind: .user, text: "first", date: Date(timeIntervalSinceNow: -100), historyIndex: 0)
        let second = ChatItem(kind: .user, text: "second request", date: Date(timeIntervalSinceNow: -50), historyIndex: 2)
        s.items = [first, ChatItem(kind: .assistant, text: "ok", final: true), second, ChatItem(kind: .assistant, text: "done", final: true)]
        s.messages = [.user("brief + first"), .assistant("ok"), .user("second request"), .assistant("done")]
        var cp = Checkpoint(label: "second")
        cp.created = Date(timeIntervalSinceNow: -40)
        cp.record(file, before: "before")
        s.checkpoints = [cp]
        let c = SessionController(session: s, root: dir, processes: ProcessManager())
        c.rewind(to: second.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "before")
        XCTAssertEqual(c.session.messages.count, 2)
        XCTAssertEqual(c.session.items.filter { $0.kind == .user }.map(\.text), ["first"])
        XCTAssertEqual(c.draft, "second request")
    }

    func testQueueStatePersistsAndRunningBecomesInterrupted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        QueuedTask.save([QueuedTask(prompt: "fix lint", state: .running), QueuedTask(prompt: "update README")], root: dir)
        let back = QueuedTask.load(dir)
        XCTAssertEqual(back.map(\.state), [.failed, .queued])
        XCTAssertEqual(back[0].summary, "Interrupted (Anvil quit).")
    }

    /// A queued task runs in its own worktree; when it can't start (no key in tests), it fails cleanly and the queue moves on.
    func testQueueRunsInAWorktreeAndMovesOn() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-q-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        _ = await Git.run(["init", "-b", "main"], in: repo)
        _ = await Git.run(["config", "user.email", "t@example.com"], in: repo)
        _ = await Git.run(["config", "user.name", "T"], in: repo)
        try "x\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(repo); _ = await Git.commit(repo, message: "init")
        // A scripted brain: each task writes a file and finishes.
        SessionController.brainFactory = { _ in
            let b = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
            var n = 0
            b.override = { _, _ in
                n += 1
                return n == 1 ? "```json\n{\"actions\": [{\"tool\": \"write_file\", \"args\": {\"path\": \"notes.md\", \"content\": \"hello\"}}]}\n```"
                              : "```json\n{\"say\": \"Wrote notes.md.\", \"done\": true}\n```"
            }
            return b
        }
        defer { SessionController.brainFactory = nil }
        let mode = AppSettings.shared.queueMode, verify = AppSettings.shared.autoVerify, review = AppSettings.shared.selfReview
        AppSettings.shared.queueMode = .bypass; AppSettings.shared.autoVerify = false; AppSettings.shared.selfReview = false
        defer { AppSettings.shared.queueMode = mode; AppSettings.shared.autoVerify = verify; AppSettings.shared.selfReview = review }
        let app = AppState()
        app.open(repo)
        app.enqueue("write notes")
        app.enqueue("write notes again")
        for _ in 0..<150 where app.queue.contains(where: { $0.state == .queued || $0.state == .running }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(app.queue.map(\.state), [.done, .done], app.queue.map { $0.summary ?? "" }.joined(separator: " | "))
        for t in app.queue {
            let branch = try XCTUnwrap(t.branch)
            XCTAssertTrue(branch.hasPrefix("anvil/"))
            let log = await Git.run(["log", "--oneline", "-n", "1", branch], in: repo)
            XCTAssertTrue(log.stdout.contains("Anvil: write notes"), "the work is committed on its branch: \(log.stdout)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("notes.md").path), "the main checkout is untouched")
    }

    func testSlashLimitParsing() {
        let c = SessionController(session: Session(projectPath: "/tmp"), root: URL(fileURLWithPath: "/tmp"), processes: ProcessManager())
        c.runCommand("limit", args: "$0.02 40", raw: "/limit $0.02 40")
        XCTAssertEqual(c.session.costLimit, 0.02)
        XCTAssertEqual(c.session.stepLimit, 40)
        c.runCommand("limit", args: "off", raw: "/limit off")
        XCTAssertEqual(c.session.costLimit, 0)
    }
}

final class BrowserTests: XCTestCase {
    func testOpenReadTypeClickEvalScreenshot() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("index.html")
        try """
        <html><head><title>Signup</title></head><body>
        <h1>Join Peep</h1><input id="email" placeholder="Email"><button onclick="document.getElementById('out').textContent='Thanks ' + document.getElementById('email').value">Sign up</button>
        <p id="out"></p></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let b = BrowserController()
        let status = await b.open(page.path)
        XCTAssertTrue(status.hasPrefix("loaded"), status)
        XCTAssertEqual(b.webView.customUserAgent, BrowserController.userAgent)
        let read = try await b.readPage()
        XCTAssertTrue(read.contains("title: Signup"), read)
        XCTAssertTrue(read.contains("[1] input(text) \"Email\""), read)
        XCTAssertTrue(read.contains("[2] button(submit) \"Sign up\""), read)
        _ = try await b.type(1, text: "d@x.io", submit: false)
        _ = try await b.click(2)
        let out = try await b.evaluate("document.getElementById('out').textContent")
        XCTAssertEqual(out, "Thanks d@x.io")
        let shot = try await b.screenshot()
        XCTAssertGreaterThan(shot.count, 1000)
        do { _ = try await b.click(99); XCTFail("missing element should throw") } catch {}
    }

    func testAgentGetsBrowserToolsOnlyWithABrowser() {
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "", visionEffort: "")
        let without = Agent(ctx: ToolContext(root: URL(fileURLWithPath: "/tmp"), processes: ProcessManager(), host: nil), brain: brain)
        XCTAssertNil(without.tools["browser_open"])
        let ctx = ToolContext(root: URL(fileURLWithPath: "/tmp"), processes: ProcessManager(), host: nil)
        ctx.browser = BrowserController()
        let with = Agent(ctx: ctx, brain: brain)
        XCTAssertNotNil(with.tools["browser_screenshot"])
        XCTAssertEqual(with.tools["browser_click"]?.kind, .network, "the preview browser never needs approval")
    }
}
