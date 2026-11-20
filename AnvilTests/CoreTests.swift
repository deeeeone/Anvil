import XCTest
@testable import Anvil

final class GitTests: XCTestCase {
    func testParseStatus() {
        let s = Git.parseStatus("""
        ## main...origin/main [ahead 2, behind 1]
         M src/a.swift
        M  src/b.swift
        ?? new file.txt
        R  old.txt -> renamed.txt
        """)
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(s.upstream, "origin/main")
        XCTAssertEqual(s.ahead, 2)
        XCTAssertEqual(s.behind, 1)
        XCTAssertEqual(s.files.map(\.path), ["src/a.swift", "src/b.swift", "new file.txt", "renamed.txt"])
        XCTAssertFalse(s.files[0].isStaged)
        XCTAssertTrue(s.files[1].isStaged)
        XCTAssertTrue(s.files[2].isUntracked)
        XCTAssertEqual(s.summary, "main ↑2 ↓1, 4 changed")
    }

    func testParseFreshRepo() {
        let s = Git.parseStatus("## No commits yet on main\n?? a.txt\n")
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(s.files.count, 1)
    }

    func testCleanCommitMessage() {
        XCTAssertEqual(Git.cleanCommitMessage("```\nAdd login form\n\nValidates email.\n```"), "Add login form\n\nValidates email.")
        XCTAssertEqual(Git.cleanCommitMessage("Commit message: \"Fix crash on empty input\""), "Fix crash on empty input")
        XCTAssertEqual(Git.cleanCommitMessage("Refactor parser — simpler"), "Refactor parser, simpler")
    }

    func testRealRepoHelpers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Git.initRepo(dir)
        _ = await Git.run(["config", "user.email", "t@example.com"], in: dir)
        _ = await Git.run(["config", "user.name", "T"], in: dir)
        try "hello\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        var st = await Git.status(dir)
        XCTAssertTrue(st.isRepo)
        XCTAssertEqual(st.files.first?.isUntracked, true)
        _ = await Git.stageAll(dir)
        let c = await Git.commit(dir, message: "Initial")
        XCTAssertEqual(c.status, 0, c.combined)
        try "hello\nworld\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        st = await Git.status(dir)
        XCTAssertEqual(st.files.map(\.label), ["modified"])
        let diff = await Git.diff(dir)
        XCTAssertTrue(diff.contains("+world"), diff)
        let log = await Git.log(dir)
        XCTAssertTrue(log.contains("Initial"))
    }

    func testNotARepo() async {
        let st = await Git.status(FileManager.default.temporaryDirectory.appendingPathComponent("definitely-missing-\(UUID().uuidString)"))
        XCTAssertFalse(st.isRepo)
    }
}

final class CompactorTests: XCTestCase {
    func testShouldCompactThreshold() {
        let big = String(repeating: "x", count: 70_000)
        let msgs = (0..<8).map { $0 % 2 == 0 ? ChatMessage.user(big) : .assistant("ok") }
        XCTAssertTrue(Compactor.shouldCompact(msgs, limit: 50_000))
        XCTAssertFalse(Compactor.shouldCompact(msgs, limit: 1_000_000))
        XCTAssertFalse(Compactor.shouldCompact(Array(msgs.prefix(4)), limit: 10), "too short to compact")
    }

    func testCompactedHistoryAlternatesAndKeepsBriefing() {
        let h = Compactor.compacted(briefing: "BRIEFING", summary: "did things")
        XCTAssertEqual(h.map(\.role), ["user", "assistant"])
        XCTAssertTrue(h[0].text.hasPrefix("BRIEFING"))
        XCTAssertTrue(h[0].text.contains("did things"))
        XCTAssertNoThrow(try ActionParser.parse(h[1].text))
    }

    func testSummaryRequestEndsWithUser() {
        let r1 = Compactor.summaryRequest([.user("a"), .assistant("b")])
        XCTAssertEqual(r1.last?.role, "user")
        XCTAssertTrue(r1.last!.text.contains("<compact>"))
        let r2 = Compactor.summaryRequest([.user("a"), .assistant("b"), .user("c")])
        XCTAssertEqual(r2.count, 3, "appends to the pending user turn")
    }

    func testSlimDropsOldImagesAndClipsInBatches() {
        var msgs: [ChatMessage] = [.user("brief", images: [(Data([1]), "image/png")])]
        for i in 0..<9 { msgs.append(i % 2 == 0 ? .assistant(String(repeating: "y", count: 9000)) : .user("z")) }
        XCTAssertEqual(msgs.count, 10)
        Compactor.slim(&msgs)
        XCTAssertFalse(msgs[0].hasImage)
        XCTAssertLessThan(msgs[1].text.count, 9000, "clipped on the 10-message boundary")
        let before = msgs.map(\.text)
        msgs.append(.assistant("n"))
        Compactor.slim(&msgs)
        XCTAssertEqual(Array(msgs.map(\.text).prefix(10)), before, "no edits between batches keeps the cache prefix stable")
    }

    func testMessageCodableDropsImages() throws {
        let m = ChatMessage.user("hi", images: [(Data([1, 2]), "image/png")])
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertFalse(back.hasImage)
        XCTAssertTrue(back.text.contains("1 image(s) omitted"))
    }
}

final class CheckpointTests: XCTestCase {
    func testRecordAndRestore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-cp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("sub/b.txt")
        try "original".write(to: a, atomically: true, encoding: .utf8)

        var cp1 = Checkpoint(label: "task 1")
        cp1.record(a, before: "original")
        try FileChange(url: a, old: "original", new: "changed").apply()
        cp1.record(a, before: "changed")   // second touch in the same task is ignored
        cp1.record(b, before: nil)
        try FileChange(url: b, old: nil, new: "new file").apply()
        XCTAssertEqual(cp1.files.count, 2)

        var cp2 = Checkpoint(label: "task 2")
        cp2.record(a, before: "changed")
        try FileChange(url: a, old: "changed", new: "changed again").apply()

        var list = [cp1, cp2]
        let restored = try Checkpoints.rewind(&list, to: cp1.id)
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(list.allSatisfy(\.restored))
    }
}

final class CommandAndContextTests: XCTestCase {
    func testSplit() {
        XCTAssertEqual(SlashCommands.split("/model glm-5")?.name, "model")
        XCTAssertEqual(SlashCommands.split("/model glm-5")?.args, "glm-5")
        XCTAssertNil(SlashCommands.split("/Users/me/file.txt is broken"))
        XCTAssertNil(SlashCommands.split("hello"))
    }

    func testCustomCommandExpansion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-cmd-\(UUID().uuidString)")
        let cmds = dir.appendingPathComponent(".anvil/commands/review")
        try FileManager.default.createDirectory(at: cmds, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "---\ndescription: Review a file\n---\nReview $ARGUMENTS for bugs.".write(to: cmds.appendingPathComponent("file.md"), atomically: true, encoding: .utf8)
        let c = SlashCommands.custom(project: dir).first { $0.name == "review:file" }
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.summary, "Review a file")
        XCTAssertEqual(c?.expand("main.swift"), "Review main.swift for bugs.")
        XCTAssertTrue(SlashCommands.suggestions("/rev", project: dir).contains { $0.name == "review:file" })
    }

    func testProjectMemoryAndLayout() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Run tests with make test.".write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("src/main.py"), atomically: true, encoding: .utf8)
        let mem = ProjectContext.memory(dir)
        XCTAssertEqual(mem.first?.name, "AGENTS.md")
        let layout = ProjectContext.layout(dir)
        XCTAssertTrue(layout.contains("main.py"))
        XCTAssertTrue(layout.contains("node_modules/ (skipped)"))
    }

    func testSessionRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-sess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: SessionStore.folder(for: dir).deletingLastPathComponent()) }
        var s = Session(projectPath: dir.path)
        s.title = "Fix login"
        s.items = [ChatItem(kind: .user, text: "hi")]
        s.messages = [.user("brief"), .assistant("ok")]
        try SessionStore.save(s)
        let back = SessionStore.load(s.id, root: dir)
        XCTAssertEqual(back?.title, "Fix login")
        XCTAssertEqual(back?.messages.count, 2)
        XCTAssertEqual(SessionStore.list(root: dir).first?.title, "Fix login")
    }

    func testModelPricing() {
        let j = JSON.parse(#"{"data": [{"id": "glm-5.3-flash-uncensored", "context_window_tokens": 1000000, "pricing": {"input_nano_usd_per_million_tokens": 150000000, "output_nano_usd_per_million_tokens": 500000000, "cached_input_nano_usd_per_million_tokens": 80000000}}]}"#)!
        let m = ModelCatalog.parseList(j)[0]
        XCTAssertEqual(m.inputPerMillion!, 0.15, accuracy: 1e-9)
        XCTAssertEqual(m.cost(prompt: 1_000_000, completion: 0, cached: 500_000)!, 0.075 + 0.04, accuracy: 1e-9)
        XCTAssertEqual(m.contextLabel, "1M ctx")
    }

    func testVisionRouting() {
        let text = [ChatMessage.user("hi")]
        let img = [ChatMessage.user("look", images: [(Data([1]), "image/png")])]
        XCTAssertEqual(Brain.route(text, model: "m", vision: "v").model, "m")
        XCTAssertEqual(Brain.route(img, model: "m", vision: "v").model, "v")
        XCTAssertEqual(Brain.route(img, model: "m", vision: "").images, false)
    }
}
