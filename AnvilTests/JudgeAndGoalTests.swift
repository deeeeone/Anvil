import XCTest
@testable import Anvil

/// The completion judge (hidden check before "done") and the /goal state. No network: the judge and the agent are scripted.
final class JudgeAndGoalTests: XCTestCase {
    var dir: URL!
    var host: TestHost!

    /// Scripted replies: the agent's turns and the judge's answers, told apart by the judge's prompt.
    final class Box {
        var agentReplies: [String] = []
        var judgeReplies: [String] = []
        var agentHistories: [[ChatMessage]] = []
        var judgePrompts: [String] = []
    }
    var box = Box()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-judge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "def add(a, b):\n    return a - b\n".write(to: dir.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        host = TestHost()
        box = Box()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func fence(_ json: String) -> String { "Reasoning.\n```json\n\(json)\n```" }

    func makeAgent() -> Agent {
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        let box = self.box
        brain.override = { history, _ in
            if history.count == 1, history[0].text.hasPrefix("COMPLETION JUDGE") {
                box.judgePrompts.append(history[0].text)
                return box.judgeReplies.isEmpty ? "{}" : box.judgeReplies.removeFirst()
            }
            box.agentHistories.append(history)
            return box.agentReplies.isEmpty ? #"{"say": "out of script", "done": true}"# : box.agentReplies.removeFirst()
        }
        let ctx = ToolContext(root: dir, processes: ProcessManager(), host: host)
        let a = Agent(ctx: ctx, brain: brain)
        a.mode = .bypass
        a.autoVerify = false
        a.selfReview = false
        a.streaming = false
        a.prepareWhilePlanning = false
        a.memory = ProjectMemory()
        return a
    }

    // A long, concrete final answer (mentions a file), so the summary check doesn't ask for a rewrite.
    let doneAnswer = "Fixed add() in calc.py so it returns a + b, and ran a check that add(2, 3) gives 5."

    // MARK: Verdicts

    func testVerdictParsing() {
        XCTAssertEqual(CompletionJudge.parse("Checked.\n```json\n{\"done\": false, \"missing\": [\"tests not run\"], \"problems\": []}\n```"),
                       Verdict(done: false, missing: ["tests not run"], problems: []))
        XCTAssertEqual(CompletionJudge.parse(#"{"done": true, "missing": [], "problems": []}"#)?.done, true)
        XCTAssertEqual(CompletionJudge.parse(#"{"say": "{\"done\": false, \"missing\": [\"README is missing\"], \"problems\": []}"}"#)?.missing,
                       ["README is missing"])
        // Done with something still open is not done.
        XCTAssertEqual(CompletionJudge.parse(#"{"done": true, "missing": ["x"], "problems": []}"#)?.done, false)
        XCTAssertNil(CompletionJudge.parse("I think it's fine, mostly."))
        XCTAssertNil(CompletionJudge.parse(#"{"missing": ["no done key"]}"#))
    }

    func testJudgeModelMapping() {
        let available = ["gemini-neon", "gemini-4-hydrogen", "glm-5.3-flash", "gemini-pro"]
        let pair = CompletionJudge.judgeModel(for: "gemini-4-hydrogen", setting: "auto", available: available)
        XCTAssertEqual(pair.model, "gemini-neon")
        XCTAssertEqual(pair.note, "gemini-neon may be the same model as gemini-4-hydrogen over Gemini web")
        let other = CompletionJudge.judgeModel(for: "glm-5.3-flash", setting: "auto", available: available)
        XCTAssertEqual(other.model, "glm-5.3-flash")
        XCTAssertNil(other.note)
        let picked = CompletionJudge.judgeModel(for: "glm-5.3-flash", setting: "gemini-pro", available: available)
        XCTAssertEqual(picked.model, "gemini-pro")
        XCTAssertNil(picked.note)
        // A setting that isn't available falls back to the session model.
        XCTAssertEqual(CompletionJudge.judgeModel(for: "glm-5.3-flash", setting: "missing-model", available: available).model, "glm-5.3-flash")
    }

    func testStrippingChecks() {
        XCTAssertEqual(CompletionJudge.strippingChecks("<observation step=2>x</observation>\n<check>A miss\n- y</check>\nreminder"),
                       "<observation step=2>x</observation>\nreminder")
        XCTAssertEqual(CompletionJudge.strippingChecks("plain text"), "plain text")
    }

    func testRepeatedMissBecomesUnresolved() {
        var t = CompletionJudge.Tracker(cap: 6)
        XCTAssertEqual(t.record(["The header is missing"]), ["The header is missing"])
        // The same miss worded differently still counts as a repeat.
        XCTAssertEqual(t.record(["the header is missing!"]), ["the header is missing!"])
        XCTAssertEqual(t.record(["The header is missing"]), [])
        XCTAssertEqual(t.unresolved, ["The header is missing"])
        XCTAssertFalse(t.exhausted)
        var capped = CompletionJudge.Tracker(cap: 2)
        _ = capped.record(["a"])
        _ = capped.record(["b"])
        XCTAssertTrue(capped.exhausted)
    }

    // MARK: Goal state

    func testCriteriaParsing() {
        let reply = """
        Plan first.
        ```json
        {"criteria": [{"text": "tests pass", "command": "python3 -m unittest"}, {"text": "README exists", "path": "README.md"}, "the answer names the files changed"], "actions": []}
        ```
        """
        let c = GoalState.parseCriteria(reply)
        XCTAssertEqual(c?.count, 3)
        XCTAssertEqual(c?[0].kind, .command)
        XCTAssertEqual(c?[0].command, "python3 -m unittest")
        XCTAssertEqual(c?[1].kind, .file)
        XCTAssertEqual(c?[1].path, "README.md")
        XCTAssertEqual(c?[2].kind, .manual)
        XCTAssertNil(GoalState.parseCriteria(#"{"say": "hi", "done": true}"#))
    }

    func testGoalStateRoundTripAndOldSessions() throws {
        var g = GoalState(objective: "ship it", budget: GoalBudget(maxMinutes: 30, maxCost: 2, maxSteps: 100), costBase: 0.5)
        g.criteria = [GoalCriterion(text: "tests pass", kind: .command, command: "make test", met: true)]
        g.phase = .waitingForProvider
        g.log("retry 1")
        let back = try JSONDecoder().decode(GoalState.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(back.objective, "ship it")
        XCTAssertEqual(back.criteria, g.criteria)
        XCTAssertEqual(back.phase, .waitingForProvider)
        XCTAssertEqual(back.budget.maxMinutes, 30)
        XCTAssertEqual(back.recovery, ["retry 1"])
        XCTAssertTrue(back.isActive)

        // A session saved before goals existed has no goal key and still decodes.
        var s = Session(projectPath: "/tmp/judge-test")
        s.goal = g
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        obj.removeValue(forKey: "goal")
        let old = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.goal)
        XCTAssertEqual(old.projectPath, "/tmp/judge-test")
    }

    // MARK: The done gate

    func testJudgeMissIsFixedHiddenAndStripped() async throws {
        box.agentReplies = [
            fence(#"{"say": "Editing.", "actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "return a - b", "replace": "return a + b"}}], "done": false}"#),
            fence("{\"say\": \"\(doneAnswer)\", \"actions\": [], \"done\": true}"),
            fence(#"{"say": "Checking.", "actions": [{"tool": "shell", "args": {"command": "python3 -c 'import calc; assert calc.add(2,3)==5; print(\"ok\")'"}}], "done": false}"#),
            fence("{\"say\": \"\(doneAnswer) The check printed ok.\", \"actions\": [], \"done\": true}"),
        ]
        box.judgeReplies = [
            #"{"done": false, "missing": ["tests not run"], "problems": []}"#,
            #"{"done": true, "missing": [], "problems": []}"#,
        ]
        let agent = makeAgent()
        let out = await agent.run(goal: "fix add")
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.text.contains("Fixed add()"))
        XCTAssertTrue(out.missing.isEmpty)
        XCTAssertEqual(box.judgePrompts.count, 2)
        // The judge never enters the conversation, and its note leaves the history once the model has answered.
        XCTAssertFalse(agent.messages.contains { $0.text.contains("COMPLETION JUDGE") })
        XCTAssertFalse(agent.messages.contains { $0.text.contains("<check>") })
        XCTAssertFalse(agent.messages.contains { $0.text.contains("tests not run") && $0.role == "assistant" })
        // The model did see the note on its next turn.
        XCTAssertTrue(box.agentHistories[2].contains { $0.text.contains("<check>") && $0.text.contains("tests not run") })
    }

    func testRepeatedMissStopsAndIsListed() async throws {
        box.agentReplies = [
            fence(#"{"say": "Editing.", "actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "return a - b", "replace": "return a + b"}}], "done": false}"#),
            fence("{\"say\": \"\(doneAnswer)\", \"actions\": [], \"done\": true}"),
            fence("{\"say\": \"\(doneAnswer)\", \"actions\": [], \"done\": true}"),
            fence("{\"say\": \"\(doneAnswer)\", \"actions\": [], \"done\": true}"),
        ]
        box.judgeReplies = Array(repeating: #"{"done": false, "missing": ["The header is missing"], "problems": []}"#, count: 3)
        let out = await makeAgent().run(goal: "fix add")
        XCTAssertTrue(out.ok)
        XCTAssertEqual(out.missing, ["The header is missing"])
        XCTAssertTrue(out.text.contains("Unresolved after review: The header is missing"))
        XCTAssertEqual(box.judgePrompts.count, 3)
    }

    func testUnusableJudgeNeverBlocks() async throws {
        box.agentReplies = [
            fence(#"{"say": "Editing.", "actions": [{"tool": "edit_file", "args": {"path": "calc.py", "find": "return a - b", "replace": "return a + b"}}], "done": false}"#),
            fence("{\"say\": \"\(doneAnswer)\", \"actions\": [], \"done\": true}"),
        ]
        box.judgeReplies = ["not json at all", "still no json"]
        let out = await makeAgent().run(goal: "fix add")
        XCTAssertTrue(out.ok)
        XCTAssertTrue(out.missing.isEmpty)
        XCTAssertEqual(box.judgePrompts.count, 2)
        XCTAssertFalse(out.text.contains("Unresolved"))
    }
}
