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
