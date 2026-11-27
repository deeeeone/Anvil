import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class GoalPanelTests: XCTestCase {
    private func goal(_ phase: GoalState.Phase = .working) -> GoalState {
        var g = GoalState(objective: "Ship the thing")
        g.phase = phase
        return g
    }

    // MARK: Chip

    func testChipTextAndTone() {
        XCTAssertEqual(GoalSummary.chip(.working).text, "Working")
        XCTAssertEqual(GoalSummary.chip(.working).tone, .accent)
        XCTAssertEqual(GoalSummary.chip(.fixing).tone, .amber)
        XCTAssertEqual(GoalSummary.chip(.waitingForProvider).text, "Waiting for provider")
        XCTAssertEqual(GoalSummary.chip(.waitingForOwner).tone, .amber)
        XCTAssertEqual(GoalSummary.chip(.done).tone, .green)
        XCTAssertEqual(GoalSummary.chip(.stopped).tone, .red)
    }

    func testLiveExcludesEndedPhases() {
        XCTAssertTrue(GoalSummary.isLive(.waitingForOwner))
        XCTAssertTrue(GoalSummary.isLive(.planning))
        XCTAssertFalse(GoalSummary.isLive(.done))
        XCTAssertFalse(GoalSummary.isLive(.stopped))
    }

    // MARK: Criteria and budget

    func testCriteriaLine() {
        XCTAssertEqual(GoalSummary.criteriaLine([]), "No criteria yet")
        let criteria = [
            GoalCriterion(text: "builds", kind: .command, command: "make", met: true),
            GoalCriterion(text: "tests", kind: .command, command: "make test", met: false),
            GoalCriterion(text: "docs"),
        ]
        XCTAssertEqual(GoalSummary.criteriaLine(criteria), "1 of 3 criteria met")
    }

    func testBudgetLineWithoutCostLimit() {
        let spent = GoalSpent(minutes: 38.7, cost: 0.12, steps: 10)
        XCTAssertEqual(GoalSummary.budgetLine(spent, GoalBudget(maxMinutes: 240, maxCost: 0)), "38 min of 240 · $0.120")
    }

    func testBudgetLineWithCostLimit() {
        let spent = GoalSpent(minutes: 5, cost: 0.12, steps: 10)
        XCTAssertEqual(GoalSummary.budgetLine(spent, GoalBudget(maxMinutes: 60, maxCost: 1)), "5 min of 60 · $0.120 of $1.00")
    }

    // MARK: Waiting reason and status

    func testWaitingReasonOnlyWhileWaiting() {
        var g = goal(.waitingForProvider)
        g.log("Provider failed (timeout); retry 1 in 30 s.")
        XCTAssertEqual(GoalSummary.waitingReason(g), "Provider failed (timeout); retry 1 in 30 s.")
        g.phase = .working
        XCTAssertNil(GoalSummary.waitingReason(g))
    }

    func testStatusTextSummarisesGoal() {
        var g = goal(.fixing)
        g.rounds = 3
        g.criteria = [GoalCriterion(text: "a", met: true), GoalCriterion(text: "b", met: false)]
        for entry in ["a", "b", "c", "d"] { g.log(entry) }
        g.unresolved = ["tests fail"]
        let text = GoalSummary.statusText(g)
        XCTAssertTrue(text.hasPrefix("Goal: Ship the thing\n"))
        XCTAssertTrue(text.contains("Phase: Fixing (round 3)"))
        XCTAssertTrue(text.contains("Criteria: 1 of 2 criteria met"))
        XCTAssertTrue(text.contains("- d\n- c\n- b"))
        XCTAssertFalse(text.contains("- a"))
        XCTAssertTrue(text.contains("Unresolved: tests fail"))
    }

    // MARK: Panel visibility

    func testShownKeepsLiveGoalsAndHidesDismissedEndedOnes() {
        XCTAssertNil(GoalSummary.shown(nil, dismissed: nil))
        let live = goal(.working)
        XCTAssertNotNil(GoalSummary.shown(live, dismissed: live.startedAt))
        let ended = goal(.done)
        XCTAssertNotNil(GoalSummary.shown(ended, dismissed: nil))
        XCTAssertNil(GoalSummary.shown(ended, dismissed: ended.startedAt))
        XCTAssertNotNil(GoalSummary.shown(ended, dismissed: Date(timeIntervalSince1970: 0)))
    }

    // MARK: SessionSummary goal phase

    private func sessionJSON(goal: String?) -> Data {
        let id = UUID().uuidString
        var json = "{\"id\": \"\(id)\", \"title\": \"Session\", \"updated\": \"2026-11-01T10:00:00Z\", \"messages\": []"
        if let goal { json += ", \"goal\": \(goal)" }
        json += "}"
        return Data(json.utf8)
    }

    func testSessionSummaryReadsGoalPhase() {
        let summary = SessionStore.summary(from: sessionJSON(goal: "{\"objective\": \"x\", \"phase\": \"working\"}"))
        XCTAssertEqual(summary?.goalPhase, "working")
        XCTAssertEqual(summary?.title, "Session")
    }

    func testSessionSummaryWithoutGoal() {
        let summary = SessionStore.summary(from: sessionJSON(goal: nil))
        XCTAssertNotNil(summary)
        XCTAssertNil(summary?.goalPhase)
    }

    func testSessionSummaryGoalWithoutPhase() {
        let summary = SessionStore.summary(from: sessionJSON(goal: "{\"objective\": \"x\"}"))
        XCTAssertNotNil(summary)
        XCTAssertNil(summary?.goalPhase)
    }
}
