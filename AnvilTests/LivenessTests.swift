import XCTest
@testable import Anvil

/// Collects what the agent sent the model (a class so the test closures can share it).
private final class PromptLog {
    var prompts: [String] = []
    var calls = 0
}

final class LivenessTests: XCTestCase {
    override func tearDown() {
        Brain.deadlines = nil
        super.tearDown()
    }

    func fence(_ json: String) -> String { "Reasoning.\n```json\n\(json)\n```" }

    // MARK: Cut-off replies

    func testIsCutOffUnclosedFence() {
        XCTAssertTrue(Brain.isCutOff("Writing it.\n```json\n{\"say\": \"x\", \"actions\": [", finishReason: nil))
    }

    func testIsCutOffUnbalancedJSON() {
        XCTAssertTrue(Brain.isCutOff("```json\n{\"say\": {\"a\": 1}\n```", finishReason: nil))
        XCTAssertTrue(Brain.isCutOff("{\"say\": \"x\", \"actions\": [{\"tool\": \"read_file\"}", finishReason: nil))
    }

    func testIsCutOffFinishReasonLength() {
        XCTAssertTrue(Brain.isCutOff(fence(#"{"say": "x", "done": true}"#), finishReason: "length"))
    }

    func testCompleteReplyIsNotCutOff() {
        XCTAssertFalse(Brain.isCutOff(fence(#"{"say": "x", "actions": [], "done": true}"#), finishReason: "stop"))
        XCTAssertFalse(Brain.isCutOff(fence(#"{"say": "a brace { in prose is fine", "done": true}"#), finishReason: nil))
        XCTAssertFalse(Brain.isCutOff("Just a plain answer with no JSON.", finishReason: nil))
    }

    func testCutOffWriteNeverRunsAndIsRetried() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anvil-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = PromptLog()
        // The first reply's write_file never closes its fence: the lenient parser could repair it into a truncated file.
        let done = fence(#"{"say": "Done.", "actions": [], "done": true}"#)
        var queue = [
            "Writing it.\n```json\n{\"say\": \"Writing.\", \"actions\": [{\"tool\": \"write_file\", \"args\": {\"path\": \"new.txt\", \"content\": \"hel",
            done,
        ]
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.override = { history, _ in
            log.prompts.append(history.last?.text ?? "")
            return queue.isEmpty ? done : queue.removeFirst()
        }
        let agent = Agent(ctx: ToolContext(root: dir, processes: ProcessManager(), host: TestHost()), brain: brain)
        agent.mode = .acceptEdits
        agent.autoVerify = false
        agent.selfReview = false
        agent.streaming = false
        agent.prepareWhilePlanning = false
        agent.memory = ProjectMemory()

        _ = await agent.run(goal: "write a file")

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path), "a cut-off write must not run")
        XCTAssertGreaterThanOrEqual(log.prompts.count, 2)
        XCTAssertTrue(log.prompts[1].contains("cut off"), "the next prompt should say the reply was cut off")
    }

    // MARK: Watchdog

    func testWatchdogRetriesASilentCall() async throws {
        Brain.deadlines = (firstToken: 0.3, idle: 0.3, turn: 30)
        let log = PromptLog()
        let brain = Brain(client: OpenAIClient(baseURL: URL(string: "http://localhost:1")!, apiKey: ""), model: "m", visionModel: "", effort: "high", visionEffort: "low")
        brain.onStream = { _ in }   // a streamed turn: without streaming only the whole-turn limit applies
        brain.override = { _, _ in
            log.calls += 1
            if log.calls == 1 { try await Task.sleep(for: .seconds(2)) }   // silent: the watchdog must cut this off
            return "answer"
        }
        let start = Date()
        let text = try await brain.reply([.user("hi")])
        let took = Date().timeIntervalSince(start)
        XCTAssertEqual(text, "answer")
        XCTAssertEqual(log.calls, 2, "the silent call should be retried once")
        XCTAssertLessThan(took, 2, "the watchdog should not wait for the silent call to finish")
    }

    // MARK: Tool budgets

    func testWithBudgetThrowsForSlowWork() async {
        do {
            _ = try await Agent.withBudget(seconds: 0.2) { () async throws -> Int in
                try await Task.sleep(for: .seconds(2))
                return 1
            }
            XCTFail("slow work should exceed its budget")
        } catch is Agent.BudgetExceeded {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testWithBudgetReturnsFastWork() async throws {
        let value = try await Agent.withBudget(seconds: 5) { () async throws -> Int in 42 }
        XCTAssertEqual(value, 42)
    }

    func testToolBudgets() {
        XCTAssertEqual(Agent.toolBudget("browser_click", group: .web, args: JSON.parse("{}")!), 60)
        XCTAssertEqual(Agent.toolBudget("browser_wait", group: .web, args: JSON.parse(#"{"timeout": 5}"#)!), 15)
        XCTAssertEqual(Agent.toolBudget("sim_tap", group: .simulator, args: JSON.parse("{}")!), 90)
        XCTAssertEqual(Agent.toolBudget("github.list_issues", group: .mcp, args: JSON.parse("{}")!), 120)
        XCTAssertEqual(Agent.toolBudget("web_search", group: .web, args: JSON.parse("{}")!), 45)
        XCTAssertNil(Agent.toolBudget("shell", group: .shell, args: JSON.parse("{}")!))
        XCTAssertNil(Agent.toolBudget("list_mcp_servers", group: .mcp, args: JSON.parse("{}")!))
    }
}
