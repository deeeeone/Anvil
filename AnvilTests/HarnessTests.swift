import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class HarnessTests: XCTestCase {
    func testRepoMapSymbols() {
        XCTAssertEqual(RepoMap.symbols(in: "class Store:\n    def add(self):\n        pass\n\ndef main():\n    pass\n", language: "py"), ["Store", ".add", "main"])
        XCTAssertEqual(RepoMap.symbols(in: "export function parse(x) {}\nexport const total = (a) => a\nclass Cart {}\n", language: "js"), ["parse", "total", "Cart"])
        XCTAssertEqual(RepoMap.symbols(in: "struct Item {}\nfinal class Store {\n    func add() {}\n}\n", language: "swift"), ["Item", "Store", "add"])
        XCTAssertEqual(RepoMap.language("tsx"), "js")
        XCTAssertNil(RepoMap.language("md"))
    }

    func testRepoMapBuild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-map-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def run():\n    pass\n".write(to: dir.appendingPathComponent("src/app.py"), atomically: true, encoding: .utf8)
        try "def test_run():\n    pass\n".write(to: dir.appendingPathComponent("test_app.py"), atomically: true, encoding: .utf8)
        let map = RepoMap.build(dir)
        XCTAssertTrue(map.contains("src/app.py: run"))
        XCTAssertTrue(map.range(of: "src/app.py")!.lowerBound < map.range(of: "test_app.py")!.lowerBound, "tests go last")
    }

    func testDiagnostics() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("good.py"), bad = dir.appendingPathComponent("bad.py"), js = dir.appendingPathComponent("bad.js")
        try "x = 1\n".write(to: good, atomically: true, encoding: .utf8)
        try "def f(:\n".write(to: bad, atomically: true, encoding: .utf8)
        try "function (\n".write(to: js, atomically: true, encoding: .utf8)
        let g = await Diagnostics.check(good)
        let b = await Diagnostics.check(bad)
        XCTAssertNil(g)
        XCTAssertNotNil(b)
        XCTAssertFalse(b!.contains(dir.path), "paths are shortened")
        let j = await Diagnostics.check(js)
        XCTAssertNotNil(j)
        XCTAssertNil(Diagnostics.command(for: URL(fileURLWithPath: "/x/readme.md")))
    }

    func testCommandClassification() {
        XCTAssertTrue(ProjectMemory.isTestCommand("npm test"))
        XCTAssertTrue(ProjectMemory.isTestCommand(".venv/bin/python -m pytest -q"))
        XCTAssertTrue(ProjectMemory.isTestCommand("python3 -m unittest test_stats.py -v"))
        XCTAssertFalse(ProjectMemory.isTestCommand("npm install"))
        XCTAssertTrue(ProjectMemory.isBuildCommand("swift build"))
        XCTAssertTrue(Agent.exercisesCode("python3 app.py"))
        XCTAssertTrue(Agent.exercisesCode("node index.js"))
        XCTAssertFalse(Agent.exercisesCode("ls -la"))
        XCTAssertFalse(Agent.exercisesCode("git add -A"))
    }

    func testGuessTestCommand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-guess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(ProjectMemory.guessTestCommand(dir))
        try #"{"scripts": {"test": "node --test"}}"#.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectMemory.guessTestCommand(dir), "npm test")
    }

    func testLessonsAreCappedAndDeduped() {
        var m = ProjectMemory()
        for i in 0..<12 { m.addLesson("lesson \(i)") }
        m.addLesson("lesson 11")
        XCTAssertEqual(m.lessons.count, 8)
        XCTAssertEqual(m.lessons.last, "lesson 11")
    }

    func testReplyCompleteDetectsClosedJSONBlock() {
        XCTAssertFalse(Brain.replyComplete("thinking\n```json\n{\"say\": \"x\""))
        XCTAssertTrue(Brain.replyComplete("thinking\n```json\n{\"say\": \"x\", \"done\": true}\n```"))
        XCTAssertTrue(Brain.replyComplete("t\n```json\n{\"actions\": []}\n```\n**Observation:** made up"))
    }
}

final class WorktreeTests: XCTestCase {
    func testWorktreeSessionLifecycle() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-wt-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        _ = await Git.run(["init", "-b", "main"], in: repo)
        _ = await Git.run(["config", "user.email", "t@example.com"], in: repo)
        _ = await Git.run(["config", "user.name", "T"], in: repo)
        try "v1\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(repo)
        _ = await Git.commit(repo, message: "init")

        guard case .success(let (dir, branch, baseBranch)) = await Git.addWorktree(repo, name: "fix it") else { return XCTFail("worktree") }
        XCTAssertEqual(baseBranch, "main")
        XCTAssertTrue(branch.hasPrefix("anvil/fix-it-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.txt").path))

        try "v2\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(dir)
        _ = await Git.commit(dir, message: "change in worktree")
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "v1\n", "the main checkout is untouched")

        let m = await Git.mergeBranch(repo, branch: branch, message: "merge")
        XCTAssertEqual(m.status, 0, m.combined)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8), "v2\n")
    }

    func testWorktreeNeedsACommit() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-wt0-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = await Git.initRepo(repo)
        if case .success = await Git.addWorktree(repo, name: "x") { XCTFail("should need a first commit") }
    }
}


final class SpeedTests: XCTestCase {
    func testRequestSizing() {
        XCTAssertEqual(RequestSize.classify("rename calc to calculateTotal"), .simple)
        XCTAssertEqual(RequestSize.classify("fix the typo in the README"), .simple)
        XCTAssertEqual(RequestSize.classify("how does the rate limiter work?"), .question)
        XCTAssertEqual(RequestSize.classify("Question only, don't change any files: what does X do"), .question)
        XCTAssertEqual(RequestSize.classify("test_shuffle.py is flaky, make it reliable"), .hard)
        XCTAssertEqual(RequestSize.classify("add a due date option to the CLI with tests"), .feature)
    }

    func testAdaptiveEffort() {
        func e(step: Int = 3, size: RequestSize = .feature, edited: Bool = false, explored: Bool = false, failed: Bool = false, verified: Bool = false, parse: Int = 0) -> String {
            AdaptiveEffort.effort(.init(step: step, size: size, editedThisRequest: edited, lastBatchExploratory: explored, lastBatchFailed: failed,
                                        verifiedSinceEdit: verified, parseFailures: parse), full: "high")
        }
        XCTAssertEqual(e(step: 1, size: .simple), "low")
        XCTAssertEqual(e(step: 1, size: .feature), "high")
        XCTAssertEqual(e(explored: true), "high", "the turn after reading decides the change")
        XCTAssertEqual(e(edited: true, verified: true), "low", "tests passed: wrapping up")
        XCTAssertEqual(e(edited: true, failed: true), "high")
        XCTAssertEqual(e(edited: true), "medium")
        XCTAssertEqual(AdaptiveEffort.cap("high", "medium"), "medium", "the setting is the ceiling")
    }

    func testTracebackLocations() {
        let py = "Traceback (most recent call last):\n  File \"/x/app.py\", line 12, in run\n  File \"lib/util.py\", line 3, in f\nZeroDivisionError"
        XCTAssertEqual(Prefetch.locations(in: py).map(\.1), [12, 3])
        let node = "TypeError: x\n    at total (/p/src/pricing.js:5:11)\n    at Object.<anonymous> (/p/index.js:2:1)"
        XCTAssertEqual(Prefetch.locations(in: node).map(\.0), ["/p/src/pricing.js", "/p/index.js"])
        XCTAssertEqual(Prefetch.locations(in: "Sources/App/main.swift:40:7: error: cannot find 'x'").first?.1, 40)
    }

    func testBriefFingerprintAndRoundTrip() throws {
        XCTAssertEqual(ProjectBrief.fingerprint(repoMap: "a"), ProjectBrief.fingerprint(repoMap: "a"))
        XCTAssertNotEqual(ProjectBrief.fingerprint(repoMap: "a"), ProjectBrief.fingerprint(repoMap: "b"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-brief-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        ProjectBrief(text: "A todo CLI.", fingerprint: "f", created: Date()).save(dir)
        XCTAssertEqual(ProjectBrief.load(dir)?.text, "A todo CLI.")
    }

    func testBriefIsGeneratedOnceAndReused() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-brief2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "def main():\n    pass\n".write(to: dir.appendingPathComponent("app.py"), atomically: true, encoding: .utf8)
        var calls = 0
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.override = { _, _ in calls += 1; return "A tiny app; entry point app.py main()." }
        let b1 = await Agent.refreshBrief(root: dir, brain: brain)
        let b2 = await Agent.refreshBrief(root: dir, brain: brain)
        XCTAssertEqual(b1?.text, "A tiny app; entry point app.py main().")
        XCTAssertEqual(b2?.text, b1?.text)
        XCTAssertEqual(calls, 1, "unchanged project: no second call")
    }

    func testFileIndexTracksAgentEdits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-index-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let idx = FileIndex(root: dir)
        let first = await idx.list()
        XCTAssertEqual(first.map(\.lastPathComponent), ["a.txt"])
        let b = dir.appendingPathComponent("b.txt")
        try "b".write(to: b, atomically: true, encoding: .utf8)
        idx.noteChanged(b, deleted: false)
        let second = await idx.list()
        XCTAssertEqual(Set(second.map(\.lastPathComponent)), ["a.txt", "b.txt"])
        idx.invalidate()
        XCTAssertFalse(idx.isBuilt)
    }
}
