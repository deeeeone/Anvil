import XCTest
@testable import AnvilCore

final class CLISmokeTests: XCTestCase {
    func testVersionExitsCleanly() async {
        let code = await CLIRouter.run(["--version"])
        XCTAssertEqual(code, ExitCode.done)
    }
}
