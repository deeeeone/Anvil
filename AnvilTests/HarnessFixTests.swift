import XCTest
@testable import Anvil

/// Fixes from a benchmark run: failures hidden behind exit code 0, stopping foreign processes, stale project
/// context, model switches for environment failures, and how long a previous request took.
final class HarnessFixTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-fix-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func mkdir(_ path: String) throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    // MARK: Output that shows a failure despite exit 0

    func testOutputMarkersFindFailures() {
        let cases = [
            "Failed to compile.",
            "src/app.ts(3,7): error TS2304: Cannot find name 'x'.",
            "✖ reports an error for invalid json",
            "✗ a case",
            "# fail 2",
            "Tests:       1 failed, 12 passed",
            "FAIL src/jsonDiff.test.ts",
            "npm ERR! code ELIFECYCLE",
            "ERR_PNPM_RECURSIVE_RUN_FIRST_FAIL",
            "SyntaxError: Unexpected token",
            "Traceback (most recent call last):",
            "BUILD FAILED in 2s",
            "error: expected ';' found '}'",
            "FAILED (failures=3)",
            "===== 4 failed, 20 passed in 1.2s =====",
            "Command failed with exit code 1",
        ]
        for line in cases {
            XCTAssertNotNil(OutputCheck.outputShowsFailure("preamble\n\(line)\nmore"), line)
        }
    }

    func testOutputMarkersIgnoreZeroFailuresAndFlags() {
        XCTAssertNil(OutputCheck.outputShowsFailure("Tests: 13 passed, 0 failed"))
        XCTAssertNil(OutputCheck.outputShowsFailure("0 failed, 5 passed"))
        XCTAssertNil(OutputCheck.outputShowsFailure("failed: 0"))
        XCTAssertNil(OutputCheck.outputShowsFailure("tsx --test --fail-fast"))
        XCTAssertNil(OutputCheck.outputShowsFailure("all good\n(no output)"))
    }

    func testOutputMarkerReturnsTheMatchingLine() {
        XCTAssertEqual(OutputCheck.outputShowsFailure("ok\n  ✖ reports an error for invalid json  \nafter"), "✖ reports an error for invalid json")
    }

    func testOrChainOutsideQuotesOnly() {
        XCTAssertTrue(OutputCheck.hasOrChain("tsx --test || tsc --noEmit"))
        XCTAssertTrue(OutputCheck.hasOrChain("npm test||echo no"))
        XCTAssertFalse(OutputCheck.hasOrChain("npm test | tee log.txt"))
        XCTAssertFalse(OutputCheck.hasOrChain("echo 'a || b'"))
        XCTAssertFalse(OutputCheck.hasOrChain("npm test && npm run build"))
    }

    func testShellExitZeroWithFailureOutputIsFailed() async throws {
        let agent = makeAgent()
        let r = await agent.execute(AgentAction(tool: "shell", args: .object(["command": .string("echo 'src/a.ts: error TS2304: nope'")])))
        XCTAssertFalse(r.result.ok)
        XCTAssertTrue(r.result.output.hasPrefix("exit code 0, but the output shows a failure: src/a.ts: error TS2304"))
        XCTAssertFalse(r.verified)
    }

    func testOrChainCommandDoesNotVerify() async throws {
        let agent = makeAgent()
        let r = await agent.execute(AgentAction(tool: "shell", args: .object(["command": .string("python3 -c 'print(1)' || echo ok")])))
        XCTAssertTrue(r.line.contains("This command uses ||"))
        XCTAssertFalse(r.verified)
    }

    // MARK: stop_process ownership

    func testForeignProcessNeedsApproval() {
        XCTAssertTrue(ShellTools.stopNeedsApproval(owner: nil, session: "s1"))
        XCTAssertTrue(ShellTools.stopNeedsApproval(owner: "other", session: "s1"))
        XCTAssertFalse(ShellTools.stopNeedsApproval(owner: "s1", session: "s1"))
    }

    func testForeignStopIsADangerousCommand() {
        let marker = ShellTools.foreignStopMarker("octave-clone-v2")
        XCTAssertEqual(marker, "kill-foreign-process octave-clone-v2")
        XCTAssertNotNil(Permissions.dangerReason(marker))
        let decision = Permissions.decide(mode: .ask, kind: .exec, command: marker, root: dir, allowed: [])
        XCTAssertEqual(decision, .ask("stops a process this session didn't start"))
    }

    func testStopOfForeignProcessAsksTheOwner() async throws {
        let agent = makeAgent()
        let foreign = ProcessManager()
        // A process another session started: stop_process must not run without the owner's OK.
        let e = try foreign.start(name: "squatter", command: "sleep 30", cwd: dir, owner: "someone-else")
        defer { foreign.stopAll() }
        XCTAssertEqual(e.owner, "someone-else")
        let ctx = ToolContext(root: dir, processes: foreign, host: nil)
        let agentForForeign = Agent(ctx: ctx, brain: agent.brain)
        agentForForeign.mode = .ask
        let r = await agentForForeign.execute(AgentAction(tool: "stop_process", args: .object(["name": .string("squatter")])))
        XCTAssertTrue(r.line.contains("DECLINED"), r.line)
        XCTAssertTrue(e.running)
    }

    // MARK: Project context

    func testDepsCountAsInstalledOnlyWithNodeModulesBin() throws {
        try write(#"{"scripts":{"build":"tsc"}}"#, "package.json")
        let url = dir!
        XCTAssertFalse(ProjectMemory.depsInstalled(url))
        XCTAssertTrue(ProjectMemory.buildCommand(url)?.contains("npm install") == true)
        try mkdir("node_modules")
        XCTAssertFalse(ProjectMemory.depsInstalled(url), "an empty node_modules is not an install")
        XCTAssertTrue(ProjectMemory.buildCommand(url)?.contains("npm install") == true)
        try mkdir("node_modules/.bin")
        XCTAssertTrue(ProjectMemory.depsInstalled(url))
        XCTAssertFalse(ProjectMemory.buildCommand(url)?.contains("npm install") == true)
    }

    func testTestFilesFoundWithinDepthThree() throws {
        try write("{}", "package.json")
        XCTAssertFalse(ProjectContext.hasTestFiles(dir))
        try write("export {}", "a/b/c/d/deep.test.ts")
        XCTAssertFalse(ProjectContext.hasTestFiles(dir), "depth 4 is out of range")
        try write("export {}", "lib/jsonDiff.test.ts")
        XCTAssertTrue(ProjectContext.hasTestFiles(dir))
    }

    func testTestFilesInTestsFolderAndSkippedDirs() throws {
        try write("{}", "package.json")
        try write("x", "node_modules/pkg/x.test.js")
        XCTAssertFalse(ProjectContext.hasTestFiles(dir), "node_modules is skipped")
        try write("it('x')", "tests/math.js")
        XCTAssertTrue(ProjectContext.hasTestFiles(dir))
    }

    func testGuessTestCommandFindsTestFilesWithoutScript() throws {
        try write(#"{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}"#, "package.json")
        try write("export {}", "lib/jsonDiff.test.ts")
        XCTAssertEqual(ProjectMemory.guessTestCommand(dir), "node --test")
        try write(#"{"devDependencies":{"tsx":"4.0.0"}}"#, "package.json")
        XCTAssertEqual(ProjectMemory.guessTestCommand(dir), "npx tsx --test")
    }

    func testGuessTestCommandNilWithoutTests() throws {
        try write(#"{"name":"empty"}"#, "package.json")
        XCTAssertNil(ProjectMemory.guessTestCommand(dir))
    }

    func testChangedCountMatchesPorcelainEntries() async throws {
        _ = await ProcessRunner.run("/usr/bin/git", ["init", "-q"], cwd: dir, timeout: 30)
        try write("ignored/\n", ".gitignore")
        try write("x", "ignored/secret.txt")
        try write("a", "a.txt")
        try write("1", "folder/1.txt")
        try write("2", "folder/2.txt")
        try write("3", "folder/3.txt")
        let folded = await Git.status(dir, untrackedAll: false)
        XCTAssertEqual(folded.files.count, 3, "a.txt, folder/ and .gitignore")
        XCTAssertTrue(folded.summary.hasSuffix("3 changed"), folded.summary)
        let all = await Git.status(dir)
        XCTAssertEqual(all.files.count, 5)
    }

    // MARK: Escalation

    func testOnlyTheModelsOwnWorkCountsTowardEscalation() {
        XCTAssertTrue(Agent.countsTowardEscalation(tool: "edit_file", command: nil, output: "no match", declined: false))
        XCTAssertTrue(Agent.countsTowardEscalation(tool: "shell", command: "npm run build", output: "exit 1", declined: false))
        XCTAssertTrue(Agent.countsTowardEscalation(tool: "shell", command: "python3 app.py", output: "exit 1", declined: false))
        XCTAssertFalse(Agent.countsTowardEscalation(tool: "shell", command: "npx tsx --test", output: "zsh: command not found: tsx", declined: false))
        XCTAssertFalse(Agent.countsTowardEscalation(tool: "shell", command: "ls /missing", output: "exit 1", declined: false))
        XCTAssertFalse(Agent.countsTowardEscalation(tool: "read_file", command: nil, output: "no such file", declined: false))
        XCTAssertFalse(Agent.countsTowardEscalation(tool: "browser_navigate", command: nil, output: "net error", declined: false))
        XCTAssertFalse(Agent.countsTowardEscalation(tool: "fetch_url", command: nil, output: "404", declined: false))
        XCTAssertFalse(Agent.countsTowardEscalation(tool: "wait_until", command: nil, output: "timed out", declined: false))
        XCTAssertFalse(Agent.countsTowardEscalation(tool: "write_file", command: nil, output: "declined", declined: true))
    }

    // MARK: Previous request timing

    func testPreviousRequestLineFormat() {
        let start = Date()
        let line = Agent.previousRequestLine(start: start, end: start.addingTimeInterval(229.6), steps: 14)
        XCTAssertTrue(line.hasPrefix("Previous request: started "), line)
        XCTAssertTrue(line.contains(", finished "), line)
        XCTAssertTrue(line.contains("(3 min 49 s), 14 steps."), line)
        XCTAssertTrue(Agent.previousRequestLine(start: start, end: start.addingTimeInterval(42), steps: 1).hasSuffix("(42 s), 1 step."))
    }

    private func makeAgent() -> Agent {
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        let agent = Agent(ctx: ToolContext(root: dir, processes: ProcessManager(), host: nil), brain: brain)
        agent.mode = .bypass
        agent.memory = ProjectMemory()
        return agent
    }
}
