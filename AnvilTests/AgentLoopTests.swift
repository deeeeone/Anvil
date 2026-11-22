import XCTest
@testable import Anvil

/// Records events and answers prompts from a script.
final class TestHost: AgentHost {
    var permissionAnswers: [PermissionAnswer] = []
    var planDecision: PlanDecision = .approve
    var steering: [String] = []
    var permissionRequests: [PermissionRequest] = []
    var steps: [(String, ToolStep.Status, [FileDiff])] = []
    var says: [(String, Bool)] = []
    var plans: [[String]] = []
    var milestones: [Int] = []
    var todos: [TodoItem] = []

    func agentStatus(_ text: String) {}
    func agentThought(_ text: String) {}
    func agentSay(_ text: String, final: Bool) { says.append((text, final)) }
    func agentStepBegan(_ id: UUID, tool: String, summary: String) {}
    func agentStepOutput(_ id: UUID, chunk: String) {}
    func agentStepEnded(_ id: UUID, status: ToolStep.Status, output: String, diffs: [FileDiff], duration: Double) { steps.append((output, status, diffs)) }
    func agentPermission(_ req: PermissionRequest) async -> PermissionAnswer {
        permissionRequests.append(req)
        return permissionAnswers.isEmpty ? .allow : permissionAnswers.removeFirst()
    }
    func agentPlan(_ steps: [String]) async -> PlanDecision { plans.append(steps); return planDecision }
    func agentMilestone(_ index: Int) { milestones.append(index) }
    func agentTodos(_ todos: [TodoItem]) { self.todos = todos }
    func agentAsk(_ question: String) async -> String? { "yes" }
    func agentDrainSteering() -> [String] { defer { steering = [] }; return steering }
    func agentError(_ text: String) {}
}

final class AgentLoopTests: XCTestCase {
    var dir: URL!
    var host: TestHost!
    var sent: [[ChatMessage]] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "def add(a, b):\n    return a - b\n".write(to: dir.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        host = TestHost()
        sent = []
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    var models: [String] = []

    func makeAgent(_ replies: [String], mode: PermissionMode = .acceptEdits, verify: Bool = false, review: Bool = false) -> Agent {
        var queue = replies
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.override = { [weak self] history, model in
            self?.sent.append(history)
            self?.models.append(model)
            return queue.isEmpty ? #"{"say": "out of script", "done": true}"# : queue.removeFirst()
        }
        let ctx = ToolContext(root: dir, processes: ProcessManager(), host: host)
        let a = Agent(ctx: ctx, brain: brain)
        a.mode = mode
        a.autoVerify = verify
        a.selfReview = review
        a.streaming = false
        a.prepareWhilePlanning = false
        a.memory = ProjectMemory()
        return a
    }

    func fence(_ json: String) -> String { "Reasoning.\n```json\n\(json)\n```" }

    func testReadEditVerifyDone() async throws {
        let agent = makeAgent([
            fence(#"{"say": "Reading.", "actions": [{"tool": "read_file", "args": {"path": "calc.py"}}], "done": false}"#),
            fence(#"{"say": "Fixing.", "actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "return a - b", "replace": "return a + b"}}, {"tool": "shell", "args": {"command": "python3 -c 'import calc; assert calc.add(2,3)==5; print(\"ok\")'"}}], "done": false}"#),
            fence(#"{"say": "Fixed add() in calc.py; verified with a quick check.", "actions": [], "done": true}"#),
        ], mode: .bypass)
        let out = await agent.run(goal: "fix add")
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.changedFiles, ["calc.py"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("calc.py"), encoding: .utf8), "def add(a, b):\n    return a + b\n")
        // The first turn carries the briefing and the read_file result arrives with line numbers.
        XCTAssertTrue(sent[0].last!.text.contains("OWNER'S REQUEST\nfix add"))
        XCTAssertTrue(sent[1].last!.text.contains("2\t    return a - b"))
        XCTAssertTrue(sent[2].last!.text.contains("exit 0"), sent[2].last!.text)
        XCTAssertEqual(host.steps.compactMap { $0.2.first }.first?.added, 1)
        XCTAssertEqual(host.says.last?.1, true)
    }

    func testAskModeShowsDiffAndRespectsDecline() async throws {
        host.permissionAnswers = [.deny("use a different approach")]
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "a - b", "replace": "a + b"}}]}"#),
            fence(#"{"say": "Okay, leaving it.", "done": true}"#),
        ], mode: .ask)
        _ = await agent.run(goal: "fix")
        XCTAssertEqual(host.permissionRequests.count, 1)
        XCTAssertTrue(host.permissionRequests[0].diffs[0].unified.contains("+    return a + b"))
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("calc.py"), encoding: .utf8).contains("a - b"), "declined edit must not be written")
        XCTAssertTrue(sent[1].last!.text.contains("DECLINED"))
        XCTAssertTrue(sent[1].last!.text.contains("use a different approach"))
    }

    func testAllowSessionSwitchesToAutoEdits() async throws {
        host.permissionAnswers = [.allowSession]
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "a.txt", "content": "1"}}]}"#),
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "b.txt", "content": "2"}}]}"#),
            fence(#"{"say": "done", "done": true}"#),
        ], mode: .ask)
        _ = await agent.run(goal: "write")
        XCTAssertEqual(host.permissionRequests.count, 1)
        XCTAssertEqual(agent.mode, .acceptEdits)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
    }

    func testBatchStopsAtFirstFailure() async throws {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "nope", "replace": "x"}}, {"tool": "write_file", "args": {"path": "never.txt", "content": "x"}}]}"#),
            fence(#"{"say": "stop", "done": true}"#),
        ])
        _ = await agent.run(goal: "x")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("never.txt").path))
        XCTAssertTrue(sent[1].last!.text.contains("remaining 1 action(s) in this batch were skipped"))
    }

    func testPlanModeDeniesEditsThenApprovedPlanUnlocks() async throws {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "x.txt", "content": "x"}}]}"#),
            fence(#"{"say": "Plan.", "plan": ["Write x", "Verify"], "actions": [], "done": false}"#),
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "x.txt", "content": "x"}}], "milestone": 1}"#),
            fence(#"{"say": "Done.", "done": true, "milestone": 2}"#),
        ], mode: .plan)
        let out = await agent.run(goal: "make x")
        XCTAssertTrue(out.ok)
        XCTAssertTrue(sent[0].last!.text.contains("PLAN MODE"))
        XCTAssertTrue(sent[1].last!.text.contains("Plan mode is read-only"))
        XCTAssertEqual(host.plans.count, 1)
        XCTAssertEqual(agent.mode, .ask, "approving a plan leaves plan mode")
        XCTAssertEqual(host.milestones, [1, 2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.txt").path))
    }

    func testPlanCancel() async {
        host.planDecision = .cancel
        let agent = makeAgent([fence(#"{"say": "Plan.", "plan": ["a", "b", "c"], "actions": [], "done": false}"#)])
        let out = await agent.run(goal: "big job")
        XCTAssertTrue(out.text.contains("cancelled"))
        XCTAssertEqual(sent.count, 1)
    }

    func testSteeringMessageReachesNextObservation() async {
        host.steering = ["also update the docstring"]
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "list_dir", "args": {}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ])
        _ = await agent.run(goal: "x")
        XCTAssertTrue(sent[1].last!.text.contains("MESSAGES SENT WHILE YOU WERE WORKING"))
        XCTAssertTrue(sent[1].last!.text.contains("also update the docstring"))
    }

    func testFollowUpReusesConversation() async {
        let agent = makeAgent([fence(#"{"say": "first", "done": true}"#), fence(#"{"say": "second", "done": true}"#)])
        _ = await agent.run(goal: "one")
        _ = await agent.run(goal: "two")
        XCTAssertEqual(sent[1].count, 3)
        XCTAssertTrue(sent[1].last!.text.hasPrefix("NEW REQUEST FROM THE OWNER"))
        XCTAssertEqual(sent[1][0].text, sent[0][0].text, "the briefing prefix stays byte-identical for the cache")
    }

    func testDoneWithActionsGetsOneMoreLook() async {
        let agent = makeAgent([
            fence(#"{"say": "done", "actions": [{"tool": "shell", "args": {"command": "echo hi"}}], "done": true}"#),
            fence(#"{"say": "Printed hi.", "done": true}"#),
        ], mode: .bypass)
        let out = await agent.run(goal: "x")
        XCTAssertEqual(out.text, "Printed hi.")
        XCTAssertTrue(sent[1].last!.text.contains("you marked this done"))
    }

    func testDangerousCommandAsksInAutoEditButNotBypass() async {
        host.permissionAnswers = [.deny(nil)]
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "shell", "args": {"command": "rm -rf ./calc.py"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .acceptEdits)
        _ = await agent.run(goal: "x")
        XCTAssertEqual(host.permissionRequests.first?.reason, "deletes files recursively")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("calc.py").path))

        let host2 = TestHost()
        self.host = host2
        let agent2 = makeAgent([
            fence(#"{"actions": [{"tool": "shell", "args": {"command": "rm -rf ./calc.py"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent2.run(goal: "x")
        XCTAssertTrue(host2.permissionRequests.isEmpty, "bypass never asks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("calc.py").path))
    }

    func testServerCommandRedirectedToStartProcess() async {
        let agent = makeAgent([fence(#"{"actions": [{"tool": "shell", "args": {"command": "python3 -m http.server 8123"}}]}"#), fence(#"{"say": "ok", "done": true}"#)], mode: .bypass)
        _ = await agent.run(goal: "x")
        XCTAssertTrue(sent[1].last!.text.contains("start_process"))
    }

    func testBackgroundProcessLifecycle() async throws {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "start_process", "args": {"command": "python3 -m http.server 8765", "name": "web"}}, {"tool": "wait_until", "args": {"until": "url", "value": "http://127.0.0.1:8765", "timeout": 20}}, {"tool": "fetch_url", "args": {"url": "http://127.0.0.1:8765"}}, {"tool": "stop_process", "args": {"name": "web"}}]}"#),
            fence(#"{"say": "Served.", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "serve")
        let obs = sent[1].last!.text
        XCTAssertTrue(obs.contains("started web"), obs)
        XCTAssertTrue(obs.contains("condition met"), obs)
        XCTAssertTrue(obs.contains("HTTP 200"), obs)
        XCTAssertTrue(obs.contains("stopped web"), obs)
    }

    func testMultiEditAcrossFilesAndCheckpoint() async throws {
        try "x = 1\n".write(to: dir.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        var saved: Checkpoint?
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "multi_edit", "args": {"edits": [{"path": "calc.py", "find": "a - b", "replace": "a + b"}, {"path": "b.py", "find": "x = 1", "replace": "x = 2"}]}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ])
        agent.onCheckpoint = { saved = $0 }
        _ = await agent.run(goal: "x")
        XCTAssertEqual(saved?.files.count, 2)
        XCTAssertEqual(host.steps.first?.2.count, 2)
        var list = [saved!]
        _ = try Checkpoints.rewind(&list, to: saved!.id)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("b.py"), encoding: .utf8), "x = 1\n")
    }

    func testParseFailureRecovery() async {
        let agent = makeAgent(["{broken json", fence(#"{"say": "recovered", "done": true}"#)])
        let out = await agent.run(goal: "x")
        XCTAssertEqual(out.text, "recovered")
        XCTAssertTrue(sent[1].last!.text.contains("couldn't be used"))
    }

    func testCompactReplacesHistory() async throws {
        let agent = makeAgent([fence(#"{"say": "first", "done": true}"#), "Summary: fixed calc.py; tests pass."])
        _ = await agent.run(goal: "one")
        try await agent.compact(focus: nil)
        XCTAssertEqual(agent.messages.count, 2)
        XCTAssertTrue(agent.messages[0].text.contains("Summary: fixed calc.py"))
        XCTAssertTrue(agent.messages[0].text.hasPrefix("You are Anvil"))
    }

    func testWriteFileRefusesBlindOverwrite() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "calc.py", "content": "x = 1\n"}}]}"#),
            fence(#"{"actions": [{"tool": "read_file", "args": {"path": "calc.py"}}, {"tool": "write_file", "args": {"path": "calc.py", "content": "x = 1\n"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        XCTAssertTrue(sent[1].last!.text.contains("haven't read it"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("calc.py"), encoding: .utf8), "x = 1\n")
    }

    func testReanchorsAModelThatSaysItCantAct() async {
        let agent = makeAgent([
            "I can’t access the project files or run commands here. Please provide wc.py.",
            fence(#"{"say": "Looked.", "actions": [{"tool": "list_dir", "args": {}}], "done": false}"#),
            fence(#"{"say": "done", "done": true}"#),
        ])
        let out = await agent.run(goal: "fix it")
        XCTAssertEqual(out.text, "done")
        XCTAssertTrue(sent[1].last!.text.contains("You do have access"))
    }

    func testReanchorsAJSONRefusal() async {
        let agent = makeAgent([
            fence(#"{"say": "I can't access the project files here. Please paste wc.py.", "actions": [], "done": true}"#),
            fence(#"{"say": "ok", "done": true}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ])
        let out = await agent.run(goal: "fix it")
        XCTAssertEqual(out.text, "ok")
        XCTAssertTrue(sent[1].last!.text.contains("You do have access"))
        // "fix it" answered with "ok" and no action is sent back once more, then accepted.
        XCTAssertTrue(sent[2].last!.text.contains("You answered without taking any action"))
    }

    func testIntentWithoutActionsIsNotAnAnswer() async {
        let agent = makeAgent([
            "I'll read the file to see why fetchAll loses its results.",
            fence(#"{"say": "Read it.", "done": true}"#),
        ])
        let out = await agent.run(goal: "x")
        XCTAssertEqual(out.text, "Read it.")
        XCTAssertTrue(sent[1].last!.text.contains("couldn't be used"))
    }

    func testAnnouncedPlanWithoutActionsIsNudged() async {
        let agent = makeAgent([
            fence(#"{"say": "The README calls for a state machine. I'll implement that behavior and check it."}"#),
            fence(#"{"say": "Implemented.", "done": true}"#),
        ])
        let out = await agent.run(goal: "x")
        XCTAssertEqual(out.text, "Implemented.")
        XCTAssertTrue(sent[1].last!.text.contains("had no actions"))
    }

    func testGrepContextNearEndOfFileDoesNotCrash() async throws {
        try "a\ncalc\nb\ncalc\ncalc\n".write(to: dir.appendingPathComponent("m.js"), atomically: true, encoding: .utf8)
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "grep", "args": {"pattern": "calc", "context": 3}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ])
        _ = await agent.run(goal: "x")
        XCTAssertTrue(sent[1].last!.text.contains("m.js:5: calc"))
    }

    func testTodoWrite() async {
        let agent = makeAgent([fence(#"{"actions": [{"tool": "todo_write", "args": {"todos": [{"content": "a", "status": "completed"}, {"content": "b", "status": "in_progress"}]}}]}"#), fence(#"{"say": "ok", "done": true}"#)])
        _ = await agent.run(goal: "x")
        XCTAssertEqual(host.todos.map(\.status), [.completed, .inProgress])
    }

    // MARK: Accuracy and speed features

    func testSyntaxCheckFlagsBrokenEdit() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "broken.py", "content": "def f(:\n    pass\n"}}, {"tool": "list_dir", "args": {}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        let obs = sent[1].last!.text
        XCTAssertTrue(obs.contains("SYNTAX CHECK FAILED"), obs)
        XCTAssertTrue(obs.contains("remaining 1 action"), "a broken file stops the batch")
    }

    func testGoodEditSaysSyntaxOK() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "a - b", "replace": "a + b"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        XCTAssertTrue(sent[1].last!.text.contains("(syntax ok)"))
    }

    func testParallelReadsKeepOrder() async throws {
        for n in ["a", "b", "c"] { try "file \(n)\n".write(to: dir.appendingPathComponent("\(n).txt"), atomically: true, encoding: .utf8) }
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "read_file", "args": {"path": "a.txt"}}, {"tool": "read_file", "args": {"path": "b.txt"}}, {"tool": "read_file", "args": {"path": "c.txt"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ])
        _ = await agent.run(goal: "x")
        let obs = sent[1].last!.text
        let ia = obs.range(of: "file a")!.lowerBound, ib = obs.range(of: "file b")!.lowerBound, ic = obs.range(of: "file c")!.lowerBound
        XCTAssertTrue(ia < ib && ib < ic)
    }

    func testRereadOfUnchangedFileIsDeduplicated() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "read_file", "args": {"path": "calc.py"}}]}"#),
            fence(#"{"actions": [{"tool": "read_file", "args": {"path": "calc.py"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ])
        _ = await agent.run(goal: "x")
        XCTAssertTrue(sent[2].last!.text.contains("unchanged since you read it at step 1"))
    }

    func testDoneGateRunsKnownTestCommand() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "a - b", "replace": "a + b"}}]}"#),
            fence(#"{"say": "Fixed add.", "done": true}"#),
        ], mode: .bypass, verify: true)
        agent.memory.testCommand = "python3 -c 'import calc; assert calc.add(2, 3) == 5'"
        let out = await agent.run(goal: "fix add")
        XCTAssertTrue(out.ok)
        XCTAssertNotNil(out.verifiedBy)
        XCTAssertTrue(out.text.contains("Verified"))
        XCTAssertEqual(sent.count, 2, "a passing auto-test costs no extra model turn")
    }

    func testDoneGateSendsFailuresBack() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "a - b", "replace": "a * b"}}]}"#),
            fence(#"{"say": "Done.", "done": true}"#),
            fence(#"{"actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "a * b", "replace": "a + b"}}]}"#),
            fence(#"{"say": "Really done.", "done": true}"#),
        ], mode: .bypass, verify: true)
        agent.memory.testCommand = "python3 -c 'import calc; assert calc.add(2, 3) == 5'"
        let out = await agent.run(goal: "fix add")
        XCTAssertTrue(sent[2].last!.text.contains("FAILED"))
        XCTAssertNotNil(out.verifiedBy)
    }

    func testDoneGateAsksToVerifyWithoutTestCommand() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "notes.md", "content": "hi"}}]}"#),
            fence(#"{"say": "Done.", "done": true}"#),
            fence(#"{"say": "Docs only, nothing to run.", "done": true}"#),
        ], mode: .bypass, verify: true)
        let out = await agent.run(goal: "write notes")
        XCTAssertTrue(sent[2].last!.text.contains("Verify the change"))
        XCTAssertEqual(out.text, "Docs only, nothing to run.")
    }

    func testShellRunAfterEditCountsAsVerification() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "a - b", "replace": "a + b"}}, {"tool": "shell", "args": {"command": "python3 -c 'import calc; print(calc.add(1,1))'"}}]}"#),
            fence(#"{"say": "Done.", "done": true}"#),
        ], mode: .bypass, verify: true)
        _ = await agent.run(goal: "x")
        XCTAssertEqual(sent.count, 2, "already verified: no gate turn")
    }

    func testSelfReviewSendsIssuesBack() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "a.py", "content": "x = 1\ny = 2\nprint('debug')\n"}}]}"#),
            fence(#"{"say": "Done.", "done": true}"#),
            "- a.py: leftover debug print",
            fence(#"{"say": "Removed it.", "done": true}"#),
        ], mode: .bypass, review: true)
        let out = await agent.run(goal: "make a.py")
        XCTAssertTrue(sent[3].last!.text.contains("leftover debug print"), sent[3].last!.text)
        XCTAssertEqual(out.text, "Removed it.")
    }

    func testReviewLGTMFinishes() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "a.py", "content": "x = 1\ny = 2\nz = 3\n"}}]}"#),
            fence(#"{"say": "Done.", "done": true}"#),
            "LGTM",
        ], mode: .bypass, review: true)
        let out = await agent.run(goal: "make a.py")
        XCTAssertEqual(out.text, "Done.")
    }

    func testEscalatesAfterRepeatedFailure() async {
        let bad = fence(#"{"actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "nope", "replace": "x"}}]}"#)
        let agent = makeAgent([bad, bad, fence(#"{"say": "ok", "done": true}"#)])
        agent.escalationModel = "deepseek-v4.1-flash-uncensored"
        _ = await agent.run(goal: "x")
        XCTAssertEqual(models[2], "deepseek-v4.1-flash-uncensored")
        XCTAssertTrue(sent[2].last!.text.contains("A different model takes the next step"))
        XCTAssertEqual(models[1], "m")
    }

    func testExploreHelperReportsBack() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "explore", "args": {"question": "where is add defined?"}}]}"#),
            fence(#"{"actions": [{"tool": "grep", "args": {"pattern": "def add"}}]}"#),
            fence(#"{"say": "add is defined in calc.py line 1.", "done": true}"#),
            fence(#"{"say": "Found it.", "done": true}"#),
        ])
        let out = await agent.run(goal: "find add")
        XCTAssertEqual(out.text, "Found it.")
        XCTAssertTrue(sent[3].last!.text.contains("explore report:\nadd is defined in calc.py line 1."), sent[3].last!.text)
        XCTAssertTrue(sent[1][0].text.contains("read-only research helper"), "the helper starts its own conversation")
        XCTAssertFalse(sent[1][0].text.contains("- explore {"), "no nested helpers")
    }

    func testPassingTestCommandIsRemembered() async throws {
        try "import unittest\nclass T(unittest.TestCase):\n    def test_a(self):\n        self.assertTrue(True)\n".write(to: dir.appendingPathComponent("test_x.py"), atomically: true, encoding: .utf8)
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "shell", "args": {"command": "python3 -m unittest -q"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        XCTAssertEqual(agent.memory.testCommand, "python3 -m unittest -q")
    }

    // MARK: Speed features

    func testLineRangeEdit() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "read_file", "args": {"path": "calc.py"}}]}"#),
            fence(#"{"actions": [{"tool": "replace_lines", "args": {"path": "calc.py", "start": 2, "end": 2, "content": "    return a + b"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("calc.py"), encoding: .utf8), "def add(a, b):\n    return a + b\n")
    }

    func testLineRangeEditNeedsAFreshRead() async throws {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "replace_lines", "args": {"path": "calc.py", "start": 2, "end": 2, "content": "x"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        XCTAssertTrue(sent[1].last!.text.contains("read_file it again"))
    }

    func testLineRangeMultipleRangesAndShiftNote() async throws {
        try "1\n2\n3\n4\n5\n".write(to: dir.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "read_file", "args": {"path": "n.txt"}}, {"tool": "replace_lines", "args": {"path": "n.txt", "ranges": [{"start": 1, "end": 1, "content": "one\nuno"}, {"start": 4, "end": 5, "content": ""}]}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("n.txt"), encoding: .utf8), "one\nuno\n2\n3\n")
        XCTAssertTrue(sent[1].last!.text.contains("moved by -1"), sent[1].last!.text)
    }

    func testTracebackPrefetch() async throws {
        try "def boom():\n    x = 1\n    return 1 / 0\n".write(to: dir.appendingPathComponent("boom.py"), atomically: true, encoding: .utf8)
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "shell", "args": {"command": "python3 -c 'import boom; boom.boom()'"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        let obs = sent[1].last!.text
        XCTAssertTrue(obs.contains("RELEVANT CODE"), obs)
        XCTAssertTrue(obs.contains(">3\t    return 1 / 0"), obs)
    }

    func testGrepPrefetchShowsSurroundingCode() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "grep", "args": {"pattern": "return a - b"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ])
        _ = await agent.run(goal: "x")
        XCTAssertTrue(sent[1].last!.text.contains("CODE AROUND THE HITS"))
    }

    func testBatchApprovalCoversTheRestOfTheReply() async throws {
        host.permissionAnswers = [.allowBatch]
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "a.txt", "content": "1"}}, {"tool": "write_file", "args": {"path": "b.txt", "content": "2"}}, {"tool": "write_file", "args": {"path": "c.txt", "content": "3"}}]}"#),
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "d.txt", "content": "4"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .ask)
        host.permissionAnswers = [.allowBatch, .allow]
        _ = await agent.run(goal: "x")
        XCTAssertEqual(host.permissionRequests.count, 2, "one card for the first reply's three edits, one for the next reply")
        XCTAssertEqual(host.permissionRequests[0].batchRemaining, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.txt").path))
    }

    func testApprovedPlanCoversItsEdits() async {
        let agent = makeAgent([
            fence(#"{"say": "Plan.", "plan": ["Write a", "Write b"], "actions": [], "done": false}"#),
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "a.txt", "content": "1"}}], "milestone": 1}"#),
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "b.txt", "content": "2"}}], "milestone": 2}"#),
            fence(#"{"say": "Done.", "done": true}"#),
        ], mode: .ask)
        _ = await agent.run(goal: "big job")
        XCTAssertTrue(host.permissionRequests.isEmpty, "approving the plan approved its edits")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
    }

    func testPlanLookAheadReportReachesTheAgent() async {
        let agent = makeAgent([
            fence(#"{"say": "Plan.", "plan": ["Fix add", "Test"], "actions": [], "done": false}"#),
            fence(#"{"say": "add is in calc.py line 2.", "done": true}"#),   // the look-ahead helper
            fence(#"{"say": "Done.", "done": true}"#),
        ], mode: .bypass)
        agent.prepareWhilePlanning = true
        _ = await agent.run(goal: "fix add")
        XCTAssertTrue(sent[2].last!.text.contains("looked ahead at milestone 1"), sent[2].last!.text)
        XCTAssertTrue(sent[2].last!.text.contains("add is in calc.py line 2."))
    }

    func testSimpleRequestUsesTheQuickModel() async {
        let agent = makeAgent([fence(#"{"say": "Renamed.", "done": true}"#)])
        agent.quickModel = "quick-m"
        _ = await agent.run(goal: "rename foo to bar in calc.py")
        XCTAssertEqual(models.first, "quick-m")
    }

    func testFillerClosersAreTrimmedFromAnswersThatChangedNothing() {
        let answer = """
        The workspace contains four projects:
        - a: a web app.
        - b: a bot.

        No changes were made, and the repository is not a git repo. If you want to explore a specific project, let me know which one to focus on.
        """
        let trimmed = Agent.trimFiller(answer)
        XCTAssertTrue(trimmed.hasSuffix("- b: a bot."), trimmed)
        XCTAssertFalse(trimmed.contains("No changes"))
        // Real content in the last paragraph stays; only the filler sentence goes.
        XCTAssertEqual(Agent.trimFiller("It uses SwiftUI. Let me know if you want more."), "It uses SwiftUI.")
        // Mid-answer mentions aren't touched, and an answer that is only filler is kept.
        XCTAssertEqual(Agent.trimFiller("Let me know if this helps, it reads config.toml first."), "Let me know if this helps, it reads config.toml first.")
        XCTAssertEqual(Agent.trimFiller("No changes were made."), "No changes were made.")
        XCTAssertEqual(Agent.trimFiller("Version 1.2 is used. See e.g. main.swift."), "Version 1.2 is used. See e.g. main.swift.")
    }

    func testClaimingNoToolsAfterActingIsReanchored() async {
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "list_dir", "args": {}}]}"#),
            fence(#"{"say": "To build this I need file, shell, and browser tools that aren't available in this environment.", "actions": [], "done": true}"#),
            fence(#"{"say": "Here is the answer.", "done": true}"#),
        ])
        let out = await agent.run(goal: "build a landing page")
        XCTAssertEqual(out.text, "Here is the answer.", "the false 'no tools' answer wasn't accepted")
        XCTAssertTrue(sent[2].last!.text.contains("You already used them successfully"), sent[2].last!.text)
    }

    func testCantActPhrasesCoverToolAvailabilityClaims() {
        XCTAssertTrue(Agent.looksLikeCantAct("I need file, shell, and browser tools that aren't available in this environment."))
        XCTAssertTrue(Agent.looksLikeCantAct("I don't have access to your file system."))
        XCTAssertFalse(Agent.looksLikeCantAct("The parser reads the config, then the tools module registers handlers."))
    }

    func testLongSandboxExcuseIsCaught() {
        let reply = "## Blueprint\n\nBecause I am running in a sandboxed environment without direct access to your local filesystem, here is a complete plan.\n" + String(repeating: "- a section of the plan with details\n", count: 120)
        XCTAssertGreaterThan(reply.count, 1200)
        XCTAssertTrue(Agent.looksLikeCantAct(reply))
    }

    func testWorkRequestAnsweredWithoutActingIsSentBack() async {
        let agent = makeAgent([
            fence(#"{"say": "Here is a full blueprint for the page: app/page.tsx with a hero, features and footer.", "actions": [], "done": true}"#),
            fence(#"{"actions": [{"tool": "list_dir", "args": {}}]}"#),
            fence(#"{"say": "Built it.", "done": true}"#),
        ])
        let out = await agent.run(goal: "make a landing page for this project with nextjs")
        XCTAssertEqual(out.text, "Built it.")
        XCTAssertTrue(sent[1].last!.text.contains("You answered without taking any action"), sent[1].last!.text)
    }

    func testQuestionsCanStillBeAnsweredWithoutActing() async {
        let agent = makeAgent([fence(#"{"say": "A Swift package manifest declares targets.", "done": true}"#)])
        let out = await agent.run(goal: "what does a Package.swift file do?")
        XCTAssertEqual(out.text, "A Swift package manifest declares targets.")
    }

    func testBigJobAsksForAPlanBeforeEditing() async {
        let goal = "build a landing page " + String(repeating: "with a hero section and feature grid and screenshots ", count: 8)
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "list_dir", "args": {}}]}"#),
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "a.txt", "content": "x"}}]}"#),
            fence(#"{"say": "Plan.", "plan": ["Scaffold", "Hero", "Features"], "actions": [], "done": false}"#),
            fence(#"{"actions": [{"tool": "write_file", "args": {"path": "a.txt", "content": "x"}}], "milestone": 1}"#),
            fence(#"{"say": "Done.", "done": true}"#),
        ], mode: .bypass)
        agent.autoVerify = false
        agent.selfReview = false
        _ = await agent.run(goal: goal)
        XCTAssertTrue(sent[2].last!.text.contains("reply first with a \"plan\""), "edits wait for a plan; reads didn't")
        XCTAssertTrue(sent[1].last!.text.contains("list_dir"), "the read-only first step ran")
    }

    func testVerificationFitsTheChangedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("verify-\(UUID().uuidString.prefix(6))")
        let site = root.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: site.appendingPathComponent("app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"scripts": {"build": "next build"}}"#.write(to: site.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: root.appendingPathComponent("test_stats.py"), atomically: true, encoding: .utf8)
        let page = site.appendingPathComponent("app/page.tsx").path
        // The remembered Python test doesn't check a .tsx change; the site's own build does (installing first).
        let cmd = ProjectMemory.verifyCommand(changed: [page], root: root, remembered: "python3 -m unittest -q")
        XCTAssertEqual(cmd, "cd site && npm install --no-audit --no-fund && npm run build")
        XCTAssertFalse(ProjectMemory.covers("python3 -m unittest -q", changed: [page]))
        XCTAssertTrue(ProjectMemory.covers("npm run build", changed: [page]))
        // A Python change still uses the remembered command.
        XCTAssertEqual(ProjectMemory.verifyCommand(changed: [root.appendingPathComponent("stats.py").path], root: root, remembered: "python3 -m unittest -q"),
                       "python3 -m unittest -q")
    }

    func testClosingNoteAboutTheChatServicesToolsIsCaught() {
        let reply = "No styles are applied because layout.tsx imports globals.css incorrectly. " + String(repeating: "Details of the diagnosis. ", count: 80)
            + "(Note: I don't have direct file/shell/browser tool declarations active in this turn's tool list, only retriever:expand_tools and retriever:expand_skills.)"
        XCTAssertTrue(Agent.looksLikeCantAct(reply))
    }

    func testGeminiCannedErrorsAreNotAnswers() {
        XCTAssertTrue(GeminiWebClient.isServiceError("Sorry, something went wrong. Please try your request again."))
        XCTAssertTrue(GeminiWebClient.isServiceError("I\u{2019}m having a hard time fulfilling your request. Can I help you with something else instead?"))
        XCTAssertFalse(GeminiWebClient.isServiceError("Reading the files.\n```json\n{\"actions\": []}\n```"))
        XCTAssertFalse(GeminiWebClient.isServiceError("The build failed because something went wrong in the postcss config, which " + String(repeating: "is explained here. ", count: 30)))
    }

    func testTighterFoldIsMuchSmaller() {
        var h: [ChatMessage] = [.user("briefing")]
        for i in 0..<20 { h.append(.assistant(String(repeating: "r\(i) ", count: 2000))); h.append(.user(String(repeating: "o\(i) ", count: 2000))) }
        let normal = Brain.fold(h).text.count
        let tight = Brain.fold(h, recent: 3, olderClip: 300, recentClip: 4000).text.count
        XCTAssertLessThan(tight, normal / 2, "normal \(normal), tight \(tight)")
    }

    func testRollingCompactionSurvivesAProviderCap() async throws {
        let agent = makeAgent([])
        var h: [ChatMessage] = [.user("You are Anvil. briefing")]
        for i in 0..<30 {
            h.append(.assistant("reply \(i) " + String(repeating: "x", count: 6000)))
            h.append(.user("observation \(i) " + String(repeating: "y", count: 6000)))
        }
        agent.messages = h
        agent.briefing = "You are Anvil. briefing"
        var calls: [[ChatMessage]] = []
        var lastSummary = ""
        agent.brain.override = { request, _ in
            let chars = request.reduce(0) { $0 + $1.charCount }
            calls.append(request)
            // A provider that refuses anything over 30k characters, like the free tier in the screenshot.
            if chars > 30_000 { throw BrainError(status: 400, code: "upstream_error", message: "This prompt is longer than the free tier allows for a single request.") }
            lastSummary = "SUMMARY after call \(calls.count)"
            return lastSummary
        }
        try await agent.compact(focus: nil)
        XCTAssertGreaterThan(calls.count, 3, "it rolled over several parts")
        XCTAssertTrue(calls.dropFirst().contains { $0.last!.text.contains("SUMMARY after call") }, "later parts carry the running summary")
        XCTAssertEqual(agent.messages.count, 2)
        XCTAssertTrue(agent.messages[0].text.contains(lastSummary), "the final rolling summary became the context")
        XCTAssertTrue(agent.messages[0].text.hasPrefix("You are Anvil"))
    }

    func testChunksKeepTurnsTogetherAndRespectTheBudget() {
        var h: [ChatMessage] = []
        for i in 0..<10 { h.append(.user("u\(i) " + String(repeating: "a", count: 900))); h.append(.assistant("a\(i) " + String(repeating: "b", count: 900))) }
        let chunks = Compactor.chunks(h, maxChars: 4000)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertEqual(chunks.flatMap { $0 }.count, 20, "nothing lost")
        XCTAssertTrue(chunks.dropFirst().allSatisfy { $0.first?.role == "user" }, "each part starts at a user turn")
        XCTAssertTrue(Compactor.isTooLong(BrainError(status: 400, code: "x", message: "Prompt is longer than the free tier allows")))
        XCTAssertFalse(Compactor.isTooLong(BrainError(status: 401, code: "unauthorized", message: "bad key")))
    }

    func testCancelledCompactionLeavesHistoryUntouched() async {
        let agent = makeAgent([])
        agent.messages = [.user("You are Anvil."), .assistant("a"), .user("b"), .assistant("c")]
        agent.brain.override = { _, _ in throw CancellationError() }
        do { try await agent.compact(focus: nil); XCTFail("should throw") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(agent.messages.count, 4, "the conversation is unchanged")
    }

    func testReviewerSeesRequirementsInUnchangedParts() async throws {
        let body = "def run(jobs):\n    \"\"\"Never start a job after one has failed.\"\"\"\n" + (0..<30).map { "    x\($0) = \($0)\n" }.joined() + "    return jobs\n"
        try body.write(to: dir.appendingPathComponent("w.py"), atomically: true, encoding: .utf8)
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "read_file", "args": {"path": "w.py"}}]}"#),
            fence(#"{"actions": [{"tool": "replace_lines", "args": {"path": "w.py", "start": 31, "end": 33, "content": "    y = 1\n    z = 2\n    q = 3"}}]}"#),
            fence(#"{"say": "Done.", "done": true}"#),
            "LGTM",
        ], mode: .bypass, review: true)
        agent.autoVerify = false
        _ = await agent.run(goal: "fix w.py so it behaves as its docstring says")
        let reviewPrompt = sent.compactMap { $0.last?.text }.first { $0.contains("You are reviewing a code change") }
        let p = try XCTUnwrap(reviewPrompt, "the reviewer was never called")
        XCTAssertTrue(p.contains("CURRENT CONTENT OF THE CHANGED FILES"), "reviewer has no file context")
        XCTAssertTrue(p.contains("Never start a job after one has failed"), "the unchanged docstring (a requirement) must reach the reviewer")
        XCTAssertTrue(p.contains("every explicit requirement"))
    }

    func testPointerOpenersAndStockClosersAreRemoved() {
        let raw = "Answered above: it's a flash loan, an uncollateralized crypto loan borrowed and repaid in one transaction, used mainly for arbitrage. No further actions needed."
        XCTAssertEqual(Agent.trimFiller(raw), "It's a flash loan, an uncollateralized crypto loan borrowed and repaid in one transaction, used mainly for arbitrage.")
        XCTAssertEqual(Agent.stripLeadingPointer("Answered above."), "Answered above.", "nothing left to show, so it's kept")
        XCTAssertEqual(Agent.stripLeadingPointer("See below: the build fails in parseWeek because of an off-by-one."), "The build fails in parseWeek because of an off-by-one.")
        XCTAssertEqual(Agent.stripLeadingPointer("Based on the search results, it is a loan."), "Based on the search results, it is a loan.")
    }
}
