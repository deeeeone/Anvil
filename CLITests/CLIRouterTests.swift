import XCTest
@testable import AnvilCore

final class CLIRouterTests: XCTestCase {
    func testVersionExitsZero() async {
        let code = await CLIRouter.run(["--version"])
        XCTAssertEqual(code, ExitCode.done)
        let word = await CLIRouter.run(["version"])
        XCTAssertEqual(word, ExitCode.done)
    }

    func testHelpExitsZero() async {
        let plain = await CLIRouter.run(["--help"])
        XCTAssertEqual(plain, ExitCode.done)
        let config = await CLIRouter.run(["config", "--help"])
        XCTAssertEqual(config, ExitCode.done)
        let topic = await CLIRouter.run(["help", "providers"])
        XCTAssertEqual(topic, ExitCode.done)
    }

    func testUnknownCommandIsUsageError() async {
        let code = await CLIRouter.run(["frobnicate"])
        XCTAssertEqual(code, ExitCode.usage)
    }

    func testUnknownCommandSuggestsTheCloseOne() async {
        let message = await MainActor.run { CLIRouter.unknownCommand("sesions") }
        XCTAssertTrue(message.contains("Did you mean sessions?"), message)
    }

    func testUnknownOptionIsUsageError() async {
        let code = await CLIRouter.run(["--frobnicate"])
        XCTAssertEqual(code, ExitCode.usage)
    }

    func testPromptFromEmptyStdinIsUsageErrorWhenNoPrompt() async {
        // -p with an empty prompt and no stdin text: the router refuses before any agent work starts.
        let opts = try? CLIOptions.parse(["-p", "   "])
        XCTAssertNotNil(opts)
        if let opts, !opts.promptFromStdin {
            let code = await CLIRouter.headless(opts)
            XCTAssertEqual(code, ExitCode.usage)
        }
    }
}
