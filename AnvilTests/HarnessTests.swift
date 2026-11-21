import XCTest
@testable import Anvil

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
