import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class ParserTests: XCTestCase {
    func testStandardReply() throws {
        let r = try ActionParser.parse("""
        I'll read the file first.
        ```json
        {"say": "Reading.", "actions": [{"tool": "read_file", "args": {"path": "a.swift"}}, {"tool": "grep", "args": {"pattern": "foo"}}], "done": false}
        ```
        """)
        XCTAssertEqual(r.thought, "I'll read the file first.")
        XCTAssertEqual(r.say, "Reading.")
        XCTAssertEqual(r.actions.map(\.tool), ["read_file", "grep"])
        XCTAssertEqual(r.actions[0].args["path"]?.string, "a.swift")
        XCTAssertFalse(r.done)
    }

    func testAliasesAndFlatArgs() throws {
        let r = try ActionParser.parse(#"{"actions": [{"action": "bash", "command": "ls"}, {"name": "str_replace", "arguments": "{\"path\": \"x\", \"find\": \"a\", \"replace\": \"b\"}"}]}"#)
        XCTAssertEqual(r.actions.map(\.tool), ["shell", "edit_file"])
        XCTAssertEqual(r.actions[0].args["command"]?.string, "ls")
        XCTAssertEqual(r.actions[1].args["find"]?.string, "a")
    }

    func testDoneActionBecomesAnswer() throws {
        let r = try ActionParser.parse(#"```json\n{"actions": [{"tool": "shell", "args": {"command": "make"}}, {"tool": "done", "args": {"message": "All good"}}]}\n```"#.replacingOccurrences(of: "\\n", with: "\n"))
        XCTAssertTrue(r.done)
        XCTAssertEqual(r.say, "All good")
        XCTAssertEqual(r.actions.map(\.tool), ["shell"])
    }

    func testPlanAndMilestone() throws {
        let r = try ActionParser.parse(#"{"say": "Plan", "plan": ["Read", {"title": "Edit"}, "Test"], "actions": [], "done": false, "milestone": 2}"#)
        XCTAssertEqual(r.plan, ["Read", "Edit", "Test"])
        XCTAssertEqual(r.milestone, 2)
        XCTAssertFalse(r.done)
    }

    func testRepairsTrailingCommasAndRawNewlines() throws {
        let raw = "```json\n{\"say\": \"ok\", \"actions\": [{\"tool\": \"write_file\", \"args\": {\"path\": \"a.txt\", \"content\": \"line1\nline2\"}},], \"done\": false}\n```"
        let r = try ActionParser.parse(raw)
        XCTAssertEqual(r.actions.first?.args["content"]?.string, "line1\nline2")
    }

    func testIgnoresCodeFencesBeforeTheJSON() throws {
        let raw = """
        Here is the file:
        ```swift
        func a() { print("{") }
        ```
        ```json
        {"say": "Writing.", "actions": [{"tool": "write_file", "args": {"path": "a.swift", "content": "x"}}], "done": false}
        ```
        """
        let r = try ActionParser.parse(raw)
        XCTAssertEqual(r.actions.first?.tool, "write_file")
    }

    func testJSONContainingMarkdownFences() throws {
        // The content of a README with ``` inside a JSON string breaks naive fence matching.
        let raw = "Writing the readme.\n```json\n{\"say\": \"Docs.\", \"actions\": [{\"tool\": \"write_file\", \"args\": {\"path\": \"README.md\", \"content\": \"# T\\n```bash\\nnpm test\\n```\\n\"}}], \"done\": false}\n```"
        let r = try ActionParser.parse(raw)
        XCTAssertEqual(r.actions.first?.tool, "write_file")
        XCTAssertTrue(r.actions.first?.args["content"]?.string?.contains("npm test") ?? false)
    }

    func testRepairsMissingBraceBetweenActions() throws {
        // Seen live: the model closed "args" but not the action object before starting the next action.
        let raw = #"```json\n{"say": "x", "actions": [{"tool": "edit_file", "args": {"path": "a", "find": "b", "replace": "c"}, {"tool": "shell", "args": {"command": "pytest -q"}}], "done": false}\n```"#.replacingOccurrences(of: "\\n", with: "\n")
        let r = try ActionParser.parse(raw)
        XCTAssertEqual(r.actions.map(\.tool), ["edit_file", "shell"])
        XCTAssertEqual(r.actions[1].args["command"]?.string, "pytest -q")
    }

    func testRepairsTruncatedReply() throws {
        let r = try ActionParser.parse(#"{"say": "x", "actions": [{"tool": "read_file", "args": {"path": "a.py"}}"#)
        XCTAssertEqual(r.actions.first?.args["path"]?.string, "a.py")
    }

    func testDiagnoseShowsWhere() {
        let d = ActionParser.diagnose(#"{"a": 1, "b": }"#)
        XCTAssertTrue(d.contains("HERE"), d)
    }

    func testFirstBlockWinsWhenModelRunsAhead() throws {
        // Seen live: reads, then an imagined observation, then a blind rewrite. Only the reads may run.
        let raw = "Let me look.\n```json\n{\"actions\": [{\"tool\": \"read_file\", \"args\": {\"path\": \"a.js\"}}], \"done\": false}\n```\n**Observation:** TOOL RESULT\n```\n1\tfoo\n```\nNow rewrite.\n```json\n{\"actions\": [{\"tool\": \"write_file\", \"args\": {\"path\": \"a.js\", \"content\": \"x\"}}]}\n```"
        let r = try ActionParser.parse(raw)
        XCTAssertEqual(r.actions.map(\.tool), ["read_file"])
        XCTAssertEqual(r.ignoredBlocks, 1)
        XCTAssertEqual(r.thought, "Let me look.")
    }

    func testQuotedPackageJSONIsNotTheReply() throws {
        let raw = "The manifest is:\n```json\n{\"name\": \"x\", \"version\": \"1.0.0\"}\n```\n```json\n{\"say\": \"ok\", \"done\": true}\n```"
        let r = try ActionParser.parse(raw)
        XCTAssertEqual(r.say, "ok")
        XCTAssertEqual(r.ignoredBlocks, 0)
    }

    func testRepairsNeverTouchFileContents() throws {
        // Raw newlines force the repair path; Python literals, JS trailing commas and // comments inside the
        // content string must survive byte for byte.
        let content = "def t():\n    assert x is True and y is None\n// not a comment here\nconst a = {b: 1,}\nsmart \u{201C}quotes\u{201D}\n"
        let raw = "```json\n{\"actions\": [{\"tool\": \"write_file\", \"args\": {\"path\": \"t.py\", \"content\": \"" + content.replacingOccurrences(of: "\"", with: "\\\"") + "\"}},], \"done\": False}\n```"
        let r = try ActionParser.parse(raw)
        XCTAssertEqual(r.actions.first?.args["content"]?.string, content)
        XCTAssertFalse(r.done)
    }

    func testSmartQuoteDelimiters() throws {
        let r = try ActionParser.parse("{\u{201C}say\u{201D}: \u{201C}hi\u{201D}, \u{201C}done\u{201D}: true}")
        XCTAssertEqual(r.say, "hi")
    }

    func testSayOnlyCountsAsDone() throws {
        let r = try ActionParser.parse(#"{"say": "The answer is 4."}"#)
        XCTAssertTrue(r.done)
    }

    func testNoJSONThrows() {
        XCTAssertThrowsError(try ActionParser.parse("just words"))
    }

    func testPlainPunctuation() {
        XCTAssertEqual(Fmt.plain("Done — tests pass"), "Done, tests pass")
        XCTAssertEqual(Fmt.plain("1–2"), "1-2")
    }

    func testAnswerWrittenAfterTheJSONBlockIsUsed() throws {
        let raw = "```json\n{\"say\": \"Answered below.\", \"actions\": [], \"done\": true}\n```\n\nShort answer: No, that's not an ExpressVPN credential set. The string is an email login plus OpenVPN and PPTP credentials and plan metadata."
        let reply = try ActionParser.parse(raw)
        XCTAssertTrue(reply.done)
        XCTAssertTrue(reply.actions.isEmpty)
        XCTAssertTrue(reply.say?.hasPrefix("Short answer: No") ?? false, reply.say ?? "nil")
        XCTAssertFalse(reply.say?.contains("Answered below") ?? false)
    }

    func testPointerDetection() {
        XCTAssertTrue(ActionParser.isPointer("Answered below."))
        XCTAssertTrue(ActionParser.isPointer(""))
        XCTAssertTrue(ActionParser.isPointer("See below:"))
        XCTAssertFalse(ActionParser.isPointer("The file imports globals.css but the layout is incomplete."))
    }

    func testRealAnswerInSayIsKeptEvenWithTrailingProse() throws {
        // A normal reply: say has the answer, trailing text is leftover chatter — don't swap it in.
        let raw = "```json\n{\"say\": \"The bug is an off-by-one in parseWeek; I fixed it.\", \"done\": true}\n```\nLet me know if you want more."
        let reply = try ActionParser.parse(raw)
        XCTAssertEqual(reply.say, "The bug is an off-by-one in parseWeek; I fixed it.")
    }
}
