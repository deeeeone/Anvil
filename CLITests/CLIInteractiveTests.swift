import XCTest
@testable import AnvilCore

final class CLIInteractiveTests: XCTestCase {
    // MARK: Diffs

    private func diff(added: Int, removed: Int = 0) -> FileDiff {
        var body = "@@ -1,\(removed) +1,\(added) @@\n"
        for i in 0..<removed { body += "-old \(i)\n" }
        for i in 0..<added { body += "+new \(i)\n" }
        return FileDiff(path: "src/app.swift", unified: body, added: added, removed: removed)
    }

    func testDiffHeaderShowsPathAndStats() {
        let lines = DiffView.lines(diff(added: 2, removed: 1), color: false)
        XCTAssertEqual(lines.first, "── src/app.swift  +2 −1")
    }

    func testDiffRowsCarrySignsWithoutColor() {
        let lines = DiffView.lines(diff(added: 1, removed: 1), color: false)
        XCTAssertTrue(lines.contains("  + new 0"))
        XCTAssertTrue(lines.contains("  - old 0"))
        for line in lines { XCTAssertFalse(line.contains("\u{1B}")) }
    }

    func testDiffUsesColorWhenAsked() {
        let lines = DiffView.lines(diff(added: 1, removed: 1), color: true)
        XCTAssertTrue(lines.contains { $0.contains("\u{1B}[32m") })   // green additions
        XCTAssertTrue(lines.contains { $0.contains("\u{1B}[31m") })   // red removals
    }

    func testDiffIsCappedWithMoreLinesNote() {
        let lines = DiffView.lines(diff(added: 100), color: false, cap: 60)
        // header + 60 rows + the "more" note
        XCTAssertEqual(lines.count, 62)
        XCTAssertEqual(lines.last, "  … 41 more lines")   // 100 rows plus the hunk header
    }

    func testShortDiffHasNoCapNote() {
        let lines = DiffView.lines(diff(added: 3), color: false, cap: 60)
        XCTAssertFalse(lines.contains { $0.contains("more lines") })
    }

    // MARK: Permission keys

    func testCommandKeys() {
        XCTAssertEqual(PermissionKeys.action(for: .char("y"), isCommand: true), .answer(.allow))
        XCTAssertEqual(PermissionKeys.action(for: .char("a"), isCommand: true), .answer(.allowSession))
        XCTAssertEqual(PermissionKeys.action(for: .char("n"), isCommand: true), .answer(.deny(nil)))
        XCTAssertEqual(PermissionKeys.action(for: .char("e"), isCommand: true), .denyWithNote)
        XCTAssertEqual(PermissionKeys.action(for: .char("b"), isCommand: true), .ignore)
    }

    func testEditKeys() {
        XCTAssertEqual(PermissionKeys.action(for: .char("y"), isCommand: false), .answer(.allow))
        XCTAssertEqual(PermissionKeys.action(for: .char("b"), isCommand: false), .answer(.allowBatch))
        XCTAssertEqual(PermissionKeys.action(for: .char("a"), isCommand: false), .answer(.allowSession))
        XCTAssertEqual(PermissionKeys.action(for: .char("e"), isCommand: false), .ignore)
    }

    func testEscapeDeniesAndOtherKeysAreIgnored() {
        XCTAssertEqual(PermissionKeys.action(for: .escape, isCommand: true), .answer(.deny(nil)))
        XCTAssertEqual(PermissionKeys.action(for: .escape, isCommand: false), .answer(.deny(nil)))
        XCTAssertEqual(PermissionKeys.action(for: .char("x"), isCommand: true), .ignore)
        XCTAssertEqual(PermissionKeys.action(for: .enter, isCommand: true), .ignore)
    }

    func testUppercaseAnswersToo() {
        XCTAssertEqual(PermissionKeys.action(for: .char("Y"), isCommand: true), .answer(.allow))
    }

    func testChoiceLinesListTheirKeys() {
        XCTAssertTrue(PermissionKeys.choiceLine(isCommand: true).contains("[e] deny with note"))
        XCTAssertTrue(PermissionKeys.choiceLine(isCommand: false).contains("[b] apply all in this reply"))
    }

    // MARK: Status line

    func testIdleLineShowsModelModeAndHints() {
        let line = Ansi.stripped(StatusLine.idle(model: "gpt-6-luna", mode: .ask, hint: nil, width: 120))
        XCTAssertTrue(line.hasPrefix("gpt-6-luna · Ask"))
        XCTAssertTrue(line.contains("⇧⇥ mode"))
        XCTAssertTrue(line.contains("/ commands"))
    }

    func testIdleLineIsTruncatedToWidth() {
        let line = StatusLine.idle(model: "a-very-long-model-identifier", mode: .acceptEdits, hint: nil, width: 24)
        XCTAssertLessThanOrEqual(Ansi.displayWidth(line), 24)
        XCTAssertTrue(Ansi.stripped(line).hasSuffix("…"))
    }

    func testBypassIsMarkedInIdleLine() {
        let line = Ansi.stripped(StatusLine.idle(model: "m", mode: .bypass, hint: nil, width: 120))
        XCTAssertTrue(line.contains("Bypass"))
    }

    func testHintReplacesTheTail() {
        let line = Ansi.stripped(StatusLine.idle(model: "m", mode: .ask, hint: "press Ctrl-C again to exit", width: 120))
        XCTAssertTrue(line.hasSuffix("press Ctrl-C again to exit"))
    }

    func testWorkingLineHasCountersAndStatus() {
        let line = Ansi.stripped(StatusLine.working(frame: "⠋", elapsed: 12, steps: 3, cost: 0.0021, contextPercent: 34,
                                                    status: "reading files", mode: .ask, width: 200))
        XCTAssertTrue(line.contains("working 12s"))
        XCTAssertTrue(line.contains("step 3"))
        XCTAssertTrue(line.contains("context 34%"))
        XCTAssertTrue(line.contains("reading files"))
    }

    func testWorkingLineOmitsContextWhenUnknown() {
        let line = Ansi.stripped(StatusLine.working(frame: "x", elapsed: 1, steps: 0, cost: 0, contextPercent: nil,
                                                    status: "", mode: .ask, width: 200))
        XCTAssertFalse(line.contains("context"))
    }

    func testWorkingLineFitsWidth() {
        let line = StatusLine.working(frame: "x", elapsed: 90, steps: 12, cost: 1.5, contextPercent: 80,
                                      status: String(repeating: "long status ", count: 20), mode: .bypass, width: 50)
        XCTAssertLessThanOrEqual(Ansi.displayWidth(line), 50)
    }

    // MARK: Commands and completion

    func testCompletesCommandNamesAtTheStartOfTheLine() {
        let out = InteractiveCommands.completions(text: "/he", cursor: 3, project: nil, files: [])
        XCTAssertEqual(out, ["/help "])
    }

    func testSeveralMatchesAreListed() {
        let out = InteractiveCommands.completions(text: "/mo", cursor: 3, project: nil, files: [])
        XCTAssertEqual(Set(out), ["/mode ", "/model "])
    }

    func testNoCommandCompletionAfterAnArgumentStarts() {
        XCTAssertEqual(InteractiveCommands.completions(text: "hi /he", cursor: 6, project: nil, files: []), [])
    }

    func testCompletesProjectFilesAfterAt() {
        let files = ["src/app.swift", "README.md", "src/util/format.swift"]
        let out = InteractiveCommands.completions(text: "look at @src/ap", cursor: 15, project: nil, files: files)
        XCTAssertTrue(out.contains("@src/app.swift"))
    }

    func testTokenAtCursor() {
        let t = InteractiveCommands.token(in: "a /he", cursor: 5)
        XCTAssertEqual(t.text, "/he")
        XCTAssertEqual(t.start, 2)
    }

    func testParseSplitsNameAndArguments() {
        let parsed = InteractiveCommands.parse("/mode edits")
        XCTAssertEqual(parsed?.name, "mode")
        XCTAssertEqual(parsed?.args, "edits")
        XCTAssertNil(InteractiveCommands.parse("plain text"))
        XCTAssertNil(InteractiveCommands.parse("/usr/bin/env"))
    }

    func testHelpListsEveryBuiltInCommand() {
        let help = InteractiveCommands.helpText(project: nil)
        for entry in InteractiveCommands.builtIns {
            XCTAssertTrue(help.contains("/" + entry.name), "missing /\(entry.name)")
        }
    }
}
