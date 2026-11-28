import XCTest
@testable import AnvilCore

final class CLIOptionsTests: XCTestCase {
    func testLongFlagWithSeparateValue() throws {
        let o = try CLIOptions.parse(["--model", "glm-5.3-flash", "--max-steps", "12"])
        XCTAssertEqual(o.model, "glm-5.3-flash")
        XCTAssertEqual(o.maxSteps, 12)
    }

    func testLongFlagWithEquals() throws {
        let o = try CLIOptions.parse(["--mode=plan", "--timeout=30.5"])
        XCTAssertEqual(o.mode, "plan")
        XCTAssertEqual(o.timeout, 30.5)
    }

    func testShortProjectFlagWithSpaceAndAttached() throws {
        XCTAssertEqual(try CLIOptions.parse(["-C", "/tmp/x"]).project, "/tmp/x")
        XCTAssertEqual(try CLIOptions.parse(["-C/tmp/y"]).project, "/tmp/y")
    }

    func testBooleansAndOutput() throws {
        let o = try CLIOptions.parse(["--approve", "--no-verify", "--quiet", "--output", "stream-json", "--continue"])
        XCTAssertTrue(o.approve)
        XCTAssertTrue(o.noVerify)
        XCTAssertFalse(o.noReview)
        XCTAssertTrue(o.quiet)
        XCTAssertTrue(o.continueLast)
        XCTAssertEqual(o.output, .streamJSON)
    }

    func testPrintWithPromptAndWithStdin() throws {
        let a = try CLIOptions.parse(["-p", "say hi"])
        XCTAssertEqual(a.prompt, "say hi")
        XCTAssertFalse(a.promptFromStdin)

        let dash = try CLIOptions.parse(["-p", "-"])
        XCTAssertNil(dash.prompt)
        XCTAssertTrue(dash.promptFromStdin)

        let bare = try CLIOptions.parse(["-p"])
        XCTAssertTrue(bare.promptFromStdin)

        // A following option is not the prompt: -p reads stdin and --model keeps its value.
        let next = try CLIOptions.parse(["-p", "--model", "x"])
        XCTAssertTrue(next.promptFromStdin)
        XCTAssertEqual(next.model, "x")
    }

    func testPositionalsAndDoubleDash() throws {
        let o = try CLIOptions.parse(["config", "set", "--", "--max-steps", "-p"])
        XCTAssertEqual(o.positionals, ["config", "set", "--max-steps", "-p"])
        XCTAssertNil(o.maxSteps)
        XCTAssertNil(o.prompt)
    }

    func testDashAloneIsPositional() throws {
        XCTAssertEqual(try CLIOptions.parse(["config", "-"]).positionals, ["config", "-"])
    }

    func testUnknownOptionSuggestsTheClosestFlag() {
        XCTAssertThrowsError(try CLIOptions.parse(["--modelx", "x"])) { error in
            let message = (error as? OptionError)?.message ?? ""
            XCTAssertTrue(message.contains("unknown option --modelx"), message)
            XCTAssertTrue(message.contains("Did you mean --model?"), message)
        }
    }

    func testUnknownOptionWithoutCloseMatchHasNoSuggestion() {
        XCTAssertThrowsError(try CLIOptions.parse(["--zzzzzzzz"])) { error in
            let message = (error as? OptionError)?.message ?? ""
            XCTAssertFalse(message.contains("Did you mean"), message)
        }
    }

    func testMissingValueIsAnError() {
        XCTAssertThrowsError(try CLIOptions.parse(["--model"]))
        XCTAssertThrowsError(try CLIOptions.parse(["-C"]))
    }

    func testBadNumbersAndEnumsAreRejected() {
        XCTAssertThrowsError(try CLIOptions.parse(["--max-steps", "ten"]))
        XCTAssertThrowsError(try CLIOptions.parse(["--max-steps", "0"]))
        XCTAssertThrowsError(try CLIOptions.parse(["--timeout", "-2"]))
        XCTAssertThrowsError(try CLIOptions.parse(["--mode", "fast"]))
        XCTAssertThrowsError(try CLIOptions.parse(["--output", "xml"]))
    }

    func testFlagDoesNotTakeAValue() {
        XCTAssertThrowsError(try CLIOptions.parse(["--approve=yes"]))
    }

    func testEditDistance() {
        XCTAssertEqual(OptionParser.distance("kitten", "sitting"), 3)
        XCTAssertEqual(OptionParser.distance("model", "modle"), 2)
        XCTAssertEqual(OptionParser.distance("model", "modelx"), 1)
        XCTAssertEqual(OptionParser.distance("", "abc"), 3)
    }
}
