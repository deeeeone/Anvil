import XCTest
@testable import AnvilCore

final class CLIHeadlessTests: XCTestCase {
    private func sample(ok: Bool = true, reason: String = "done") -> HeadlessSummary {
        HeadlessSummary(ok: ok, answer: "Hi \"there\"\nline two / slash", exitReason: reason, steps: 3, seconds: 1.25,
                        cost: 0.0123, calls: 2, prompt: 900, completion: 40, cached: 512, model: "glm-5.3-flash",
                        changed: ["a.swift", "dir/b.swift"], session: "6D82E6F6-0000-0000-0000-000000000000", verified: "swift test")
    }

    func testJSONResultHasTheDocumentedKeysAndTypes() async throws {
        try await MainActor.run {
            let line = HeadlessRun.resultLine(sample(), format: .json)
            XCTAssertFalse(line.contains("\n"))
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(Set(obj.keys), ["ok", "answer", "exitReason", "steps", "seconds", "cost", "calls", "tokens", "model", "changed", "session", "verified"])
            XCTAssertEqual(obj["ok"] as? Bool, true)
            XCTAssertEqual(obj["answer"] as? String, "Hi \"there\"\nline two / slash")
            XCTAssertEqual(obj["exitReason"] as? String, "done")
            XCTAssertEqual(obj["steps"] as? Int, 3)
            XCTAssertEqual(obj["seconds"] as? Double, 1.25)
            XCTAssertEqual(obj["changed"] as? [String], ["a.swift", "dir/b.swift"])
            XCTAssertNil(obj["type"], "plain json output has no type key")
            let tokens = try XCTUnwrap(obj["tokens"] as? [String: Any])
            XCTAssertEqual(tokens["prompt"] as? Int, 900)
            XCTAssertEqual(tokens["completion"] as? Int, 40)
            XCTAssertEqual(tokens["cached"] as? Int, 512)
        }
    }

    func testJSONKeysAreSorted() async {
        await MainActor.run {
            let line = HeadlessRun.resultLine(sample(), format: .json)
            // "answer" sorts before "calls" before "ok": the first key in the text is "answer".
            XCTAssertTrue(line.hasPrefix("{\"answer\""), line)
        }
    }

    func testStreamResultIsTheLastLineWithTypeResult() async throws {
        try await MainActor.run {
            let line = HeadlessRun.resultLine(sample(ok: false, reason: "max_steps"), format: .streamJSON)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(obj["type"] as? String, "result")
            XCTAssertEqual(obj["exitReason"] as? String, "max_steps")
            XCTAssertEqual(obj["ok"] as? Bool, false)
        }
    }

    func testNonFiniteNumbersStayValidJSON() async throws {
        try await MainActor.run {
            var s = sample()
            s.cost = .nan
            s.seconds = .infinity
            let line = HeadlessRun.resultLine(s, format: .json)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(obj["cost"] as? Double, 0)
        }
    }

    func testStreamJSONEventLinesParseAndEndWithResult() async throws {
        try await MainActor.run {
            let host = HeadlessHost(format: .streamJSON, quiet: true, approve: false)
            var lines: [String] = []
            host.sink = { lines.append($0) }
            let step = UUID()
            host.agentStatus("working")
            host.agentThought("thinking about it")
            host.agentStream("Hel")
            host.agentStream("Hello")
            host.agentStream("")
            host.agentStepBegan(step, tool: "shell", summary: "$ ls")
            host.agentStepEnded(step, status: .ok, output: "a\nb", diffs: [], duration: 0.2)
            host.agentSay("done", final: true)
            host.agentError("The provider rejected the API key. Check it in Settings.")
            lines.append(HeadlessRun.resultLine(sample(), format: .streamJSON))

            var types: [String] = []
            for line in lines {
                let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], line)
                types.append(try XCTUnwrap(obj["type"] as? String, line))
            }
            XCTAssertEqual(types.last, "result")
            XCTAssertEqual(types.first, "status")
            XCTAssertTrue(types.contains("stream"))
            XCTAssertTrue(types.contains("step_end"))
            XCTAssertTrue(types.contains("error"))
        }
    }

    func testStreamSendsOnlyTheNewPart() async throws {
        try await MainActor.run {
            let host = HeadlessHost(format: .streamJSON, quiet: true, approve: false)
            var deltas: [String] = []
            host.sink = { line in
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], obj["type"] as? String == "stream" {
                    deltas.append(obj["text"] as? String ?? "")
                }
            }
            host.agentStream("Hel")
            host.agentStream("Hello")
            host.agentStream("")
            host.agentStream("Again")
            XCTAssertEqual(deltas, ["Hel", "lo", "Again"])
        }
    }

    func testFailureClassificationFromAgentMessages() async {
        await MainActor.run {
            XCTAssertEqual(HeadlessExit.classify("The provider rejected the API key. Check it in Settings."), .provider)
            XCTAssertEqual(HeadlessExit.classify("The provider is rate limiting (HTTP 429). Try again in a moment."), .provider)
            XCTAssertEqual(HeadlessExit.classify("The model took too long to answer."), .provider)
            XCTAssertEqual(HeadlessExit.classify("Couldn't reach the provider: offline"), .provider)
            XCTAssertEqual(HeadlessExit.classify("Provider error 500: boom"), .provider)
            XCTAssertEqual(HeadlessExit.classify("No API key yet for this model's provider. Add one in Settings (or import keys from Peep)."), .config)
            XCTAssertEqual(HeadlessExit.classify("Sign in to Gemini first: pick a Gemini model from the model menu, or open Settings → Provider."), .config)
            XCTAssertNil(HeadlessExit.classify("Auto-compact failed: disk full"))
            XCTAssertNil(HeadlessExit.classify("glm-5.3-flash failed: slow. Switched to deepseek and retrying."))
        }
    }

    func testHostRecordsTheLastProviderFailure() async {
        await MainActor.run {
            let host = HeadlessHost(format: .text, quiet: true, approve: false)
            host.agentError("Auto-compact failed: disk full")
            XCTAssertNil(host.failure)
            host.agentError("The provider rejected the API key. Check it in Settings.")
            XCTAssertEqual(host.failure, .provider)
            XCTAssertEqual(host.failureText, "The provider rejected the API key. Check it in Settings.")
        }
    }

    func testExitCodeMapping() async {
        await MainActor.run {
            XCTAssertEqual(HeadlessExit.code(reason: "done"), 0)
            XCTAssertEqual(HeadlessExit.code(reason: "max_steps"), 1)
            XCTAssertEqual(HeadlessExit.code(reason: "cost_limit"), 1)
            XCTAssertEqual(HeadlessExit.code(reason: "judge_rejected"), 1)
            XCTAssertEqual(HeadlessExit.code(reason: "timeout"), 1)
            XCTAssertEqual(HeadlessExit.code(reason: "provider"), 3)
            XCTAssertEqual(HeadlessExit.code(reason: "no_provider"), 2)
            XCTAssertEqual(HeadlessExit.code(reason: "cancelled"), 130)
        }
    }

    func testReasonPrecedence() async {
        await MainActor.run {
            func reason(ok: Bool = false, interrupted: Bool = false, timedOut: Bool = false, failure: FailureKind? = nil,
                        steps: Int = 1, maxSteps: Int = 10, costLimit: Double = 0, spent: Double = 0, missing: [String] = []) -> String {
                HeadlessExit.reason(ok: ok, interrupted: interrupted, timedOut: timedOut, failure: failure, steps: steps,
                                    maxSteps: maxSteps, costLimit: costLimit, spent: spent, missing: missing)
            }
            XCTAssertEqual(reason(ok: true), "done")
            XCTAssertEqual(reason(interrupted: true), "cancelled")
            XCTAssertEqual(reason(timedOut: true), "timeout")
            XCTAssertEqual(reason(failure: .provider), "provider")
            XCTAssertEqual(reason(failure: .config), "no_provider")
            XCTAssertEqual(reason(steps: 10), "max_steps")
            XCTAssertEqual(reason(costLimit: 0.5, spent: 0.6), "cost_limit")
            XCTAssertEqual(reason(missing: ["tests not run"]), "judge_rejected")
            XCTAssertEqual(reason(), "stopped")
        }
    }

    func testNoProviderHintNamesTheCommands() async {
        await MainActor.run {
            let hint = HeadlessRun.noProviderHint("")
            XCTAssertTrue(hint.contains("anvil providers add"), hint)
            XCTAssertTrue(hint.contains("anvil config set api-key"), hint)
        }
    }
}
