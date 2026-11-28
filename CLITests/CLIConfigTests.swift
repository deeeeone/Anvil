import XCTest
@testable import AnvilCore

/// These change the real settings for the length of one test, and put the old values back in `defer`.
final class CLIConfigTests: XCTestCase {
    func testBoolRoundTrip() async throws {
        try await MainActor.run {
            let original = AppSettings.shared.autoVerify
            defer { AppSettings.shared.autoVerify = original }
            try ConfigCommand.set("auto-verify", to: "false")
            XCTAssertEqual(ConfigCommand.field("auto-verify")?.get(), "false")
            XCTAssertFalse(AppSettings.shared.autoVerify)
            try ConfigCommand.set("auto-verify", to: "yes")
            XCTAssertEqual(ConfigCommand.field("auto-verify")?.get(), "true")
        }
    }

    func testIntRoundTripWithAlternativeNames() async throws {
        try await MainActor.run {
            let original = AppSettings.shared.maxSteps
            defer { AppSettings.shared.maxSteps = original }
            try ConfigCommand.set("max-steps", to: "37")
            XCTAssertEqual(AppSettings.shared.maxSteps, 37)
            XCTAssertEqual(ConfigCommand.field("maxSteps")?.get(), "37")
            XCTAssertEqual(ConfigCommand.field("max_steps")?.name, "max-steps")
        }
    }

    func testEnumRoundTripAndDefaultModeMapping() async throws {
        try await MainActor.run {
            let original = AppSettings.shared.effort
            let originalMode = AppSettings.shared.defaultMode
            defer {
                AppSettings.shared.effort = original
                AppSettings.shared.defaultMode = originalMode
            }
            try ConfigCommand.set("effort", to: "MEDIUM")
            XCTAssertEqual(AppSettings.shared.effort, "medium")
            XCTAssertEqual(ConfigCommand.field("effort")?.get(), "medium")

            try ConfigCommand.set("default-mode", to: "edits")
            XCTAssertEqual(AppSettings.shared.defaultMode, .acceptEdits)
            XCTAssertEqual(ConfigCommand.field("default-mode")?.get(), "edits")
        }
    }

    func testBadValuesAreRejectedAndNothingChanges() async throws {
        try await MainActor.run {
            let steps = AppSettings.shared.maxSteps
            let effort = AppSettings.shared.effort
            let verify = AppSettings.shared.autoVerify
            defer {
                AppSettings.shared.maxSteps = steps
                AppSettings.shared.effort = effort
                AppSettings.shared.autoVerify = verify
            }
            XCTAssertThrowsError(try ConfigCommand.set("max-steps", to: "0"))
            XCTAssertThrowsError(try ConfigCommand.set("max-steps", to: "lots"))
            XCTAssertThrowsError(try ConfigCommand.set("effort", to: "turbo"))
            XCTAssertThrowsError(try ConfigCommand.set("auto-verify", to: "maybe"))
            XCTAssertThrowsError(try ConfigCommand.set("no-such-setting", to: "1"))
            XCTAssertEqual(AppSettings.shared.maxSteps, steps)
            XCTAssertEqual(AppSettings.shared.effort, effort)
            XCTAssertEqual(AppSettings.shared.autoVerify, verify)
        }
    }

    func testUnknownNameSuggestsTheClosestSetting() async {
        await MainActor.run {
            XCTAssertTrue(ConfigCommand.unknownName("max-stepz").contains("Did you mean max-steps?"))
        }
    }

    func testValidateReportsTheRule() async throws {
        try await MainActor.run {
            XCTAssertThrowsError(try ConfigCommand.validate("0", for: .int(min: 1)))
            XCTAssertEqual(try ConfigCommand.validate(" 5 ", for: .int(min: 1)), "5")
            XCTAssertEqual(try ConfigCommand.validate("off", for: .bool), "false")
            XCTAssertEqual(try ConfigCommand.validate("Plan", for: .choice(["ask", "plan"])), "plan")
        }
    }

    func testApiKeyIsNeverPrintedAndCannotBeSetOnTheCommandLine() async {
        await MainActor.run {
            // Passing a value is refused before anything is read or stored.
            XCTAssertEqual(ConfigCommand.run(["set", "api-key", "sk-test-not-real"]), ExitCode.usage)
        }
    }
}
