import XCTest
@testable import Anvil

/// Parallel queue, sub-session merging, LSP checks and GitHub helpers.
final class ParallelAgentsTests: XCTestCase {
    // MARK: LSP

    func testFrameReaderSplitsMessagesAcrossChunks() {
        let r = LSP.FrameReader()
        let a = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
        let b = #"{"jsonrpc":"2.0","method":"x","params":{"é":1}}"#
        let stream = Data("Content-Length: \(Data(a.utf8).count)\r\n\r\n\(a)Content-Length: \(Data(b.utf8).count)\r\n\r\n\(b)".utf8)
        var got: [JSON] = []
        // Feed in awkward pieces, splitting headers and bodies.
        var i = stream.startIndex
        while i < stream.endIndex {
            let j = stream.index(i, offsetBy: min(7, stream.distance(from: i, to: stream.endIndex)))
            got += r.feed(stream[i..<j])
            i = j
        }
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0]["id"]?.int, 1)
        XCTAssertEqual(got[1]["method"]?.string, "x")
    }

    func testOnlyIntroducedErrorsAreReported() {
        let old = LSP.Diagnostic(line: 3, message: "Cannot find module 'x'", source: "ts")
        let moved = LSP.Diagnostic(line: 9, message: "Cannot find module 'x'", source: "ts")
        let new = LSP.Diagnostic(line: 4, message: "Type 'string' is not assignable to type 'number'.", source: "ts")
        let lines = LSP.introduced(after: [moved, new], baseline: [old.key], path: "a.ts")
        XCTAssertEqual(lines, ["a.ts:4: Type 'string' is not assignable to type 'number'. [ts]"])
    }

    func testNoServerForSwiftWithoutPackage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(LSP.server(for: dir.appendingPathComponent("a.swift"), root: dir))
        XCTAssertNil(LSP.server(for: dir.appendingPathComponent("a.js"), root: dir), "plain JS without a tsconfig/jsconfig isn't checked")
    }

    /// Needs /tmp/anvil-lsp-ts (TypeScript 7, its own server, pull diagnostics) set up with npm i.
    func testTypeScriptServerReportsNewErrorLive() async throws {
        try await checkTypeScript(at: "/tmp/anvil-lsp-ts")
    }

    /// Needs /tmp/anvil-lsp-ts5 (TypeScript 5 + typescript-language-server, push diagnostics).
    func testTypeScript5ServerReportsNewErrorLive() async throws {
        try await checkTypeScript(at: "/tmp/anvil-lsp-ts5")
    }

    private func checkTypeScript(at path: String) async throws {
        let root = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("node_modules/typescript").path) else {
            throw XCTSkip("no TypeScript project in \(path)")
        }
        let file = root.appendingPathComponent("check-\(UUID().uuidString.prefix(6)).ts")
        defer { try? FileManager.default.removeItem(at: file) }
        let good = "export function add(a: number, b: number): number { return a + b }\n"
        let bad = good + "export const n: number = add(1, \"2\")\n"
        try good.write(to: file, atomically: true, encoding: .utf8)
        let server = try XCTUnwrap(LSP.server(for: file, root: root))
        let first = await LSP.errors(file, text: good, root: root, server: server)
        let before = try XCTUnwrap(first, "server didn't answer")
        XCTAssertTrue(before.isEmpty, "\(before)")
        try bad.write(to: file, atomically: true, encoding: .utf8)
        let second = await LSP.errors(file, text: bad, root: root, server: server)
        let after = try XCTUnwrap(second)
        let lines = LSP.introduced(after: after, baseline: Set(before.map(\.key)), path: "check.ts")
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("check.ts:2:") ?? false, "\(lines)")
    }

    // MARK: Merging

    private func repo() async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] { _ = await Git.run(args, in: dir) }
        try "one\ntwo\nthree\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(dir)
        _ = await Git.commit(dir, message: "base")
        return dir
    }

    func testMergeConflictsAreDetectedBeforeMerging() async throws {
        let dir = try await repo()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await Git.run(["checkout", "-q", "-b", "side"], in: dir)
        try "one\nSIDE\nthree\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(dir); _ = await Git.commit(dir, message: "side")
        _ = await Git.run(["checkout", "-q", "main"], in: dir)
        let clean = await Git.mergeConflicts(dir, branch: "side")
        XCTAssertEqual(clean, [], "main hasn't moved, so side merges cleanly")

        try "one\nMAIN\nthree\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(dir); _ = await Git.commit(dir, message: "main")
        let conflicts = await Git.mergeConflicts(dir, branch: "side")
        XCTAssertEqual(conflicts, ["a.txt"])
        let st = await Git.status(dir)
        XCTAssertTrue(st.files.isEmpty, "checking for conflicts must not touch the working tree")
    }

    func testParseMergeTree() {
        XCTAssertEqual(Git.parseMergeTreeConflicts("abc123\na.txt\nsrc/b.swift\na.txt\n"), ["a.txt", "src/b.swift"])
    }

    // MARK: GitHub

    func testGitHubRemoteParsing() {
        XCTAssertEqual(GitHub.repo(fromRemote: "git@github.com:octo/hello-world.git"), "octo/hello-world")
        XCTAssertEqual(GitHub.repo(fromRemote: "https://github.com/octo/hello-world"), "octo/hello-world")
        XCTAssertEqual(GitHub.repo(fromRemote: "https://github.com/octo/hello.world.git"), "octo/hello.world")
        XCTAssertNil(GitHub.repo(fromRemote: "https://gitlab.com/octo/x.git"))
    }

    func testIssueTaskPrompt() {
        let p = GitHub.issuePrompt(number: 12, title: "Crash on empty input", body: "Steps: run it with ''", repo: "o/r")
        XCTAssertTrue(p.contains("#12"))
        XCTAssertTrue(p.contains("Crash on empty input"))
        XCTAssertTrue(p.contains("gh_pr_create"))
    }

    // MARK: Sub-sessions end to end

    /// The main session splits a change in two, both sub-sessions run at once in their own worktrees,
    /// report back, and the main session merges both branches.
    func testMainSessionSpawnsWaitsAndMergesSubSessions() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-sub-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] { _ = await Git.run(args, in: repo) }
        try "x\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(repo); _ = await Git.commit(repo, message: "init")

        func reply(_ json: String) -> String { "```json\n\(json)\n```" }
        var waitedResult = ""
        SessionController.brainFactory = { _ in
            let b = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
            var n = 0
            b.override = { history, _ in
                n += 1
                let first = history.first?.text ?? ""
                if first.contains("You are a sub-session") {
                    let name = first.contains("YOUR TASK (api)") ? "api" : "ui"
                    return n == 1 ? reply(#"{"actions": [{"tool": "write_file", "args": {"path": "\#(name).txt", "content": "\#(name)"}}]}"#)
                                  : reply(#"{"say": "Wrote \#(name).txt.", "done": true}"#)
                }
                switch n {
                case 1: return reply(#"{"actions": [{"tool": "spawn_session", "args": {"name": "api", "task": "write api.txt"}}, {"tool": "spawn_session", "args": {"name": "ui", "task": "write ui.txt"}}]}"#)
                case 2: return reply(#"{"actions": [{"tool": "wait_sessions", "args": {}}]}"#)
                case 3:
                    waitedResult = history.last?.text ?? ""
                    return reply(#"{"actions": [{"tool": "merge_session", "args": {"name": "api"}}, {"tool": "merge_session", "args": {"name": "ui"}}]}"#)
                default: return reply(#"{"say": "Merged both parts.", "done": true}"#)
                }
            }
            return b
        }
        defer { SessionController.brainFactory = nil }
        let s = AppSettings.shared
        let saved = (s.queueMode, s.autoVerify, s.selfReview, s.parallelTasks, s.defaultMode, s.lspChecks)
        s.queueMode = .bypass; s.autoVerify = false; s.selfReview = false; s.parallelTasks = 2; s.defaultMode = .bypass; s.lspChecks = false
        defer { (s.queueMode, s.autoVerify, s.selfReview, s.parallelTasks, s.defaultMode, s.lspChecks) = saved }

        let app = AppState()
        app.open(repo)
        let main = try XCTUnwrap(app.current)
        var finished: AgentOutcome?
        main.onFinish = { finished = $0 }
        main.start(goal: "build the feature", display: "build the feature")
        for _ in 0..<300 where finished == nil { try await Task.sleep(for: .milliseconds(100)) }

        let outcome = try XCTUnwrap(finished, "the main session didn't finish")
        XCTAssertTrue(outcome.ok, outcome.text)
        XCTAssertEqual(app.subSessions.count, 2)
        XCTAssertEqual(Set(app.subSessions.map(\.state)), [.merged])
        XCTAssertTrue(waitedResult.contains("REPORT"), waitedResult)
        XCTAssertTrue(waitedResult.contains("api.txt") && waitedResult.contains("ui.txt"), waitedResult)
        for f in ["api.txt", "ui.txt"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(f).path), "\(f) merged into the main checkout")
        }
        let log = await Git.log(repo, count: 5)
        XCTAssertTrue(log.contains("Merge sub-session api") && log.contains("Merge sub-session ui"), log)
    }

    func testConflictingSubSessionIsNotMergedBlindly() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-subc-\(UUID().uuidString)")
        let repo = base.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] { _ = await Git.run(args, in: repo) }
        try "x\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = await Git.stageAll(repo); _ = await Git.commit(repo, message: "init")

        func reply(_ json: String) -> String { "```json\n\(json)\n```" }
        var mergeResult = ""
        SessionController.brainFactory = { _ in
            let b = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
            var n = 0
            b.override = { history, _ in
                n += 1
                let first = history.first?.text ?? ""
                if first.contains("You are a sub-session") {
                    let name = first.contains("YOUR TASK (one)") ? "one" : "two"
                    switch n {
                    case 1: return reply(#"{"actions": [{"tool": "read_file", "args": {"path": "a.txt"}}]}"#)
                    case 2: return reply(#"{"actions": [{"tool": "write_file", "args": {"path": "a.txt", "content": "\#(name)\n"}}]}"#)
                    default: return reply(#"{"say": "done", "done": true}"#)
                    }
                }
                switch n {
                case 1: return reply(#"{"actions": [{"tool": "spawn_session", "args": {"name": "one", "task": "change a.txt"}}, {"tool": "spawn_session", "args": {"name": "two", "task": "change a.txt"}}]}"#)
                case 2: return reply(#"{"actions": [{"tool": "wait_sessions", "args": {}}]}"#)
                case 3: return reply(#"{"actions": [{"tool": "merge_session", "args": {"name": "one"}}, {"tool": "merge_session", "args": {"name": "two"}}]}"#)
                default:
                    if mergeResult.isEmpty { mergeResult = history.last?.text ?? "" }
                    return reply(#"{"say": "two conflicts; stopping here", "done": true}"#)
                }
            }
            return b
        }
        defer { SessionController.brainFactory = nil }
        let s = AppSettings.shared
        let saved = (s.queueMode, s.autoVerify, s.selfReview, s.parallelTasks, s.defaultMode, s.lspChecks)
        s.queueMode = .bypass; s.autoVerify = false; s.selfReview = false; s.parallelTasks = 2; s.defaultMode = .bypass; s.lspChecks = false
        defer { (s.queueMode, s.autoVerify, s.selfReview, s.parallelTasks, s.defaultMode, s.lspChecks) = saved }

        let app = AppState()
        app.open(repo)
        let main = try XCTUnwrap(app.current)
        var finished: AgentOutcome?
        main.onFinish = { finished = $0 }
        main.start(goal: "change a.txt twice", display: "change a.txt twice")
        for _ in 0..<300 where finished == nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotNil(finished)
        XCTAssertTrue(mergeResult.contains("would conflict in: a.txt"), mergeResult)
        XCTAssertEqual(app.subSessions.first { $0.name == "one" }?.state, .merged)
        XCTAssertEqual(app.subSessions.first { $0.name == "two" }?.state, .finished)
        let content = try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8)
        XCTAssertEqual(content, "one\n", "the second branch wasn't merged over the first")
        let st = await Git.status(repo)
        XCTAssertTrue(st.files.isEmpty, "no half-done merge left behind")
    }
}
