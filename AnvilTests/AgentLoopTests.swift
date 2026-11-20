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

    func makeAgent(_ replies: [String], mode: PermissionMode = .acceptEdits) -> Agent {
        var queue = replies
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.override = { [weak self] history, _ in
            self?.sent.append(history)
            return queue.isEmpty ? #"{"say": "out of script", "done": true}"# : queue.removeFirst()
        }
        let ctx = ToolContext(root: dir, processes: ProcessManager(), host: host)
        let a = Agent(ctx: ctx, brain: brain)
        a.mode = mode
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
        XCTAssertTrue(sent[1].last!.text.contains("MESSAGE FROM THE OWNER"))
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

    func testDangerousCommandAsksEvenInBypass() async {
        host.permissionAnswers = [.deny(nil)]
        let agent = makeAgent([
            fence(#"{"actions": [{"tool": "shell", "args": {"command": "rm -rf ./calc.py"}}]}"#),
            fence(#"{"say": "ok", "done": true}"#),
        ], mode: .bypass)
        _ = await agent.run(goal: "x")
        XCTAssertEqual(host.permissionRequests.first?.reason, "deletes files recursively")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("calc.py").path))
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
        ])
        let out = await agent.run(goal: "fix it")
        XCTAssertEqual(out.text, "ok")
        XCTAssertTrue(sent[1].last!.text.contains("You do have access"))
    }

    func testTodoWrite() async {
        let agent = makeAgent([fence(#"{"actions": [{"tool": "todo_write", "args": {"todos": [{"content": "a", "status": "completed"}, {"content": "b", "status": "in_progress"}]}}]}"#), fence(#"{"say": "ok", "done": true}"#)])
        _ = await agent.run(goal: "x")
        XCTAssertEqual(host.todos.map(\.status), [.completed, .inProgress])
    }
}
