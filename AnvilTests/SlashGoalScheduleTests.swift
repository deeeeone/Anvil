import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class SlashGoalScheduleTests: XCTestCase {
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func date(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: h, minute: m))! }

    func testScheduleInAndEvery() {
        let now = date(10, 0)
        guard case .add(let a) = ScheduleParser.parse("in 30m run the tests", now: now, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(a.prompt, "run the tests")
        XCTAssertEqual(a.next, now.addingTimeInterval(1800))
        XCTAssertFalse(a.isRecurring)
        guard case .add(let b) = ScheduleParser.parse("in 2 hours check issues", now: now, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(b.prompt, "check issues"); XCTAssertEqual(b.next, now.addingTimeInterval(7200))
        guard case .add(let c) = ScheduleParser.parse("every 2h pull and test", now: now, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(c.interval, 7200); XCTAssertEqual(c.prompt, "pull and test")
        XCTAssertEqual(ScheduleParser.parse("every 1m spam"), .invalid("Repeats must be at least 5 minutes apart."))
    }

    func testScheduleAtAndDaily() {
        let now = date(10, 0)
        guard case .add(let a) = ScheduleParser.parse("at 14:30 deploy", now: now, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(a.next, date(14, 30))
        guard case .add(let b) = ScheduleParser.parse("at 9am standup notes", now: now, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(b.next, cal.date(byAdding: .day, value: 1, to: date(9, 0)), "9:00 already passed, so tomorrow")
        guard case .add(let c) = ScheduleParser.parse("daily at 09:00 summarize yesterday", now: now, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(c.dailyMinutes, 540); XCTAssertEqual(c.prompt, "summarize yesterday")
        guard case .add(let d) = ScheduleParser.parse("every day at 18:15 backup", now: now, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(d.dailyMinutes, 18 * 60 + 15); XCTAssertEqual(d.next, date(18, 15))
        XCTAssertEqual(c.following(after: date(9, 1), calendar: cal), cal.date(byAdding: .day, value: 1, to: date(9, 0)))
    }

    func testScheduleListCancelAndErrors() {
        XCTAssertEqual(ScheduleParser.parse(""), .list)
        XCTAssertEqual(ScheduleParser.parse("list"), .list)
        XCTAssertEqual(ScheduleParser.parse("cancel 2"), .cancel(2))
        if case .invalid = ScheduleParser.parse("in 30m") {} else { XCTFail("needs a task") }
        if case .invalid = ScheduleParser.parse("at 25:00 x") {} else { XCTFail("bad time") }
        if case .invalid = ScheduleParser.parse("whenever x") {} else { XCTFail("unknown form") }
    }

    func testIntervalSkipsMissedRuns() {
        let t = ScheduledTask(prompt: "x", next: date(8, 0), interval: 3600)
        XCTAssertEqual(t.following(after: date(12, 30)), date(13, 30), "after a long gap it runs once, not once per missed hour")
    }

    func testGoalModeNeverAsksAndContinuesAtTheStepLimit() async {
        let c = SessionController(session: Session(projectPath: "/tmp"), root: URL(fileURLWithPath: "/tmp"), processes: ProcessManager())
        c.mode = .ask
        c.session.stepLimit = 12
        c.startGoalForTest()
        XCTAssertTrue(c.goalMode)
        XCTAssertEqual(c.mode, .acceptEdits)
        XCTAssertEqual(c.session.stepLimit, 300)
        let answer = await c.agentAsk("Which color?")
        XCTAssertTrue(answer?.contains("Goal mode") ?? false)
        XCTAssertNil(c.pendingQuestion)
        let plan = await c.agentPlan(["a", "b", "c"])
        XCTAssertEqual(plan, .approve)
    }

    func testPromptsStateTheRules() {
        XCTAssertTrue(SessionController.grillPrompt("a login page").contains("ONE question at a time"))
        XCTAssertTrue(SessionController.grillPrompt("a login page").contains("a login page"))
        XCTAssertTrue(SessionController.goalPrompt("fix the build").contains("COMPLETELY finished"))
        XCTAssertTrue(SlashCommands.builtIns.map(\.name).contains("goal") && SlashCommands.builtIns.map(\.name).contains("grill-me") && SlashCommands.builtIns.map(\.name).contains("schedule"))
    }
}

extension SessionController {
    /// Test hook: enters goal mode the way /goal does, without starting an agent.
    func startGoalForTest() {
        runCommandStateOnly()
    }
}
