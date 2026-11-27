import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class DesignCritiqueTests: XCTestCase {
    private typealias DC = DesignCritique

    func testIsUIWork() {
        XCTAssertTrue(DC.isUIWork(uiRequest: true, changedPaths: []))
        XCTAssertTrue(DC.isUIWork(uiRequest: false, changedPaths: ["src/App.TSX"]))
        XCTAssertFalse(DC.isUIWork(uiRequest: false, changedPaths: ["main.py", "README.md"]))
    }

    func testBriefStartsWithHeaderAndFitsLimit() {
        XCTAssertTrue(DC.brief.hasPrefix("DESIGN BRIEF (for this UI task)"))
        XCTAssertLessThan(DC.brief.count, 1200)
    }

    func testParseReadsFencedReplyCapsAndSorts() {
        var items: [String] = []
        for i in 0..<8 { items.append(#"{"severity": "minor", "where": "p\#(i)", "change": "minor change \#(i)"}"#) }
        items.append(#"{"severity": "major", "where": "hero", "change": "major change"}"#)
        items.append(#"{"severity": "Blocker", "where": "nav", "change": "blocker change"}"#)
        let reply = "Here is my review.\n```json\n{\"score\": 82, \"fixes\": [\(items.joined(separator: ", "))]}\n```"
        guard let critique = DC.parse(reply) else { return XCTFail("no critique parsed") }
        XCTAssertEqual(critique.score, 82)
        XCTAssertEqual(critique.fixes.count, 8)
        XCTAssertEqual(critique.fixes[0].severity, .blocker)
        XCTAssertEqual(critique.fixes[0].change, "blocker change")
        XCTAssertEqual(critique.fixes[1].severity, .major)
        XCTAssertTrue(critique.fixes.dropFirst(2).allSatisfy { $0.severity == .minor })
    }

    func testParseClampsScore() {
        XCTAssertEqual(DC.parse(#"{"score": 140, "fixes": []}"#)?.score, 100)
        XCTAssertEqual(DC.parse(#"{"score": -5, "fixes": []}"#)?.score, 0)
        XCTAssertEqual(DC.parse(#"{"score": "77", "fixes": []}"#)?.score, 77)
    }

    func testParseAcceptsLocationAliasAndUnknownSeverity() {
        let reply = #"{"score": 50, "fixes": [{"severity": "major", "location": "header", "change": "Shrink the logo"}, {"severity": "huge", "where": "footer", "change": "Add spacing"}]}"#
        let critique = DC.parse(reply)
        XCTAssertEqual(critique?.fixes.first, DC.Fix(severity: .major, location: "header", change: "Shrink the logo"))
        XCTAssertEqual(critique?.fixes.last?.severity, .minor)
    }

    func testParseSkipsFixesWithoutChange() {
        let reply = #"{"score": 50, "fixes": [{"severity": "major", "where": "x", "change": "  "}]}"#
        XCTAssertEqual(DC.parse(reply)?.fixes.count, 0)
    }

    func testParseReturnsNilWithoutScoreOrObject() {
        XCTAssertNil(DC.parse(#"{"fixes": []}"#))
        XCTAssertNil(DC.parse("nothing useful here"))
    }

    func testOverflowIsTheFirstBlocker() {
        let audit: [String: Any] = [
            "viewportWidth": 375, "documentWidth": 520, "overflowCount": 2,
            "overflowExamples": ["div.wide ends at 520px", "img ends at 480px", "p ends at 400px"],
            "consoleErrors": 1,
        ]
        let fixes = DC.checkFixes(audit: audit, extra: ["focusNoStyle": 0])
        XCTAssertEqual(fixes.first?.severity, .blocker)
        XCTAssertEqual(fixes.first?.location, "page at 375px")
        XCTAssertTrue(fixes.first?.change.contains("document 520px wide") ?? false)
        XCTAssertTrue(fixes.first?.change.contains("div.wide ends at 520px; img ends at 480px") ?? false)
        XCTAssertFalse(fixes.first?.change.contains("p ends at 400px") ?? true)
        XCTAssertEqual(fixes.last?.change, "1 console errors on the page.")
    }

    func testLowContrastIsAMajorFix() {
        let audit: [String: Any] = [
            "samples": [
                ["fg": "rgb(200, 200, 200)", "bg": "rgb(255, 255, 255)", "fontSize": 14, "weight": 400, "font": "Inter", "text": "Faint hint"],
            ],
        ]
        let fixes = DC.checkFixes(audit: audit, extra: [:])
        XCTAssertEqual(fixes.count, 1)
        XCTAssertEqual(fixes.first?.severity, .major)
        XCTAssertEqual(fixes.first?.location, "text")
        XCTAssertTrue(fixes.first?.change.contains("\"Faint hint\"") ?? false)
        XCTAssertTrue(fixes.first?.change.contains("(needs 4.5:1)") ?? false)
    }

    func testThreeFontFamiliesIsMinor() {
        let samples: [[String: Any]] = ["Inter", "Georgia", "Menlo"].map {
            ["fg": "rgb(0, 0, 0)", "bg": "rgb(255, 255, 255)", "fontSize": 16, "weight": 400, "font": $0, "text": "Text"]
        }
        let fixes = DC.checkFixes(audit: ["samples": samples], extra: [:])
        XCTAssertEqual(fixes.count, 1)
        XCTAssertEqual(fixes.first?.severity, .minor)
        XCTAssertTrue(fixes.first?.change.contains("Uses 3 font families") ?? false)
    }

    func testFocusAndColourChecks() {
        let fixes = DC.checkFixes(audit: [:], extra: ["focusNoStyle": 2, "focusChecked": 5, "focusExamples": ["button.cta", "a#more"], "colors": 14])
        XCTAssertEqual(fixes.map(\.severity), [.minor, .major])
        let focus = fixes.first { $0.location == "focus styles" }
        XCTAssertEqual(focus?.severity, .major)
        XCTAssertEqual(focus?.change, "2 of 5 focusable elements show no visible focus style, e.g. button.cta, a#more.")
    }

    func testCleanInputGivesNoFixes() {
        let audit: [String: Any] = [
            "viewportWidth": 375, "documentWidth": 375, "overflowCount": 0, "consoleErrors": 0,
            "samples": [["fg": "rgb(0, 0, 0)", "bg": "rgb(255, 255, 255)", "fontSize": 16, "weight": 400, "font": "Inter", "text": "Body"]],
        ]
        XCTAssertEqual(DC.checkFixes(audit: audit, extra: ["colors": 6, "focusNoStyle": 0, "focusChecked": 4]), [])
    }

    func testMergeDedupesAndCaps() {
        let checks = [DC.Fix(severity: .major, location: "focus styles", change: "Make the button bigger")]
        var critic = [DC.Fix(severity: .major, location: "cta", change: "make the button bigger  ")]
        critic += (0..<9).map { DC.Fix(severity: .minor, location: "p\($0)", change: "change \($0)") }
        let merged = DC.merge(checks: checks, critic: critic)
        XCTAssertEqual(merged.count, 8)
        XCTAssertEqual(merged.first, checks[0])
        XCTAssertEqual(merged.filter { $0.change.lowercased().hasPrefix("make the button") }.count, 1)
    }

    func testActionableDropsMinors() {
        let fixes = [DC.Fix(severity: .blocker, location: "a", change: "1"), DC.Fix(severity: .major, location: "b", change: "2"),
                     DC.Fix(severity: .minor, location: "c", change: "3")]
        XCTAssertEqual(DC.actionable(fixes).count, 2)
    }

    func testNoteListsFixesAndStrips() {
        let fixes = [DC.Fix(severity: .blocker, location: "nav", change: "Stack the links"),
                     DC.Fix(severity: .major, location: "hero", change: "Shrink the heading")]
        let note = DC.note(score: 60, fixes: fixes)
        XCTAssertTrue(note.contains("<design-check>"))
        XCTAssertTrue(note.contains("- [blocker] nav: Stack the links"))
        XCTAssertTrue(note.contains("- [major] hero: Shrink the heading"))
        XCTAssertTrue(note.contains("score 60/100"))
        XCTAssertEqual(DC.strippingNotes("before\n" + note + "\nafter"), "before\nafter")
    }

    func testSummary() {
        XCTAssertEqual(DC.summary(score: 82, fixCount: 2), "Design check: 82/100, 2 fixes")
        XCTAssertEqual(DC.summary(score: 91, fixCount: 0), "Design check: 91/100, looks good")
    }

    func testTrackerRevertsWhenScoreDrops() {
        var t = DC.Tracker()
        XCTAssertEqual(t.record(score: 60, actionable: 2), .fix)
        XCTAssertEqual(t.record(score: 75, actionable: 2), .fix)
        XCTAssertEqual(t.record(score: 70, actionable: 2), .revert)
        XCTAssertEqual(t.bestScore, 75)
        XCTAssertEqual(t.bestRound, 2)
    }

    func testTrackerStopsWithoutImprovement() {
        var t = DC.Tracker()
        XCTAssertEqual(t.record(score: 60, actionable: 2), .fix)
        XCTAssertEqual(t.record(score: 60, actionable: 2), .accept)
    }

    func testTrackerAcceptsWhenNothingActionable() {
        var t = DC.Tracker()
        XCTAssertEqual(t.record(score: 90, actionable: 0), .accept)
    }

    func testTrackerCapsAtThreeRounds() {
        var t = DC.Tracker(cap: 3)
        XCTAssertEqual(t.record(score: 50, actionable: 1), .fix)
        XCTAssertEqual(t.record(score: 60, actionable: 1), .fix)
        XCTAssertEqual(t.record(score: 70, actionable: 1), .accept)
        XCTAssertTrue(t.exhausted)
    }

    func testPromptHasGoalShotsAndChecks() {
        let text = DC.prompt(goal: "Build a fancy pricing page", checks: ["overflow: 2 elements"], shots: ["desktop 1440x900", "phone 390x844"])
        XCTAssertTrue(text.contains("Build a fancy pricing page"))
        XCTAssertTrue(text.contains("desktop 1440x900"))
        XCTAssertTrue(text.contains("phone 390x844"))
        XCTAssertTrue(text.contains("1. desktop 1440x900"))
        XCTAssertTrue(text.contains("AUTOMATED CHECKS"))
        XCTAssertTrue(text.contains("- overflow: 2 elements"))
        XCTAssertTrue(DC.prompt(goal: "x", checks: [], shots: []).contains("none"))
    }
}

final class AnnouncesIntentTests: XCTestCase {
    func testPromiseAfterALabelOrAFileNameCounts() {
        XCTAssertTrue(Agent.announcesIntent("Small tweak: I'll enlarge the signup button in index.html, then verify it in the browser."))
        XCTAssertTrue(Agent.announcesIntent("The bug is in the parser. I'll fix it and run the tests."))
        XCTAssertTrue(Agent.announcesIntent("Let me check the logs."))
    }

    func testAFinishedAnswerDoesNotCount() {
        XCTAssertFalse(Agent.announcesIntent("Made the signup button larger in index.html and checked it in the browser."))
        XCTAssertFalse(Agent.announcesIntent("The page is at http://localhost:8770/index.html."))
    }
}
