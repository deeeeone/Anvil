import XCTest
@testable import Anvil

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
}
