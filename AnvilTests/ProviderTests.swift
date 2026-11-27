import XCTest
#if SWIFT_PACKAGE
@testable import AnvilCore
#else
@testable import Anvil
#endif

final class ProviderTests: XCTestCase {
    func testProviderMapping() {
        XCTAssertEqual(Providers.provider(for: "glm-5.3-flash-uncensored"), .experiential)
        XCTAssertEqual(Providers.provider(for: "deepseek-v4.1-flash"), .experiential)
        XCTAssertEqual(Providers.provider(for: "gemini-auto"), .gemini)
        XCTAssertEqual(Providers.provider(for: "gpt-6-luna"), .luna)
        XCTAssertEqual(Providers.provider(for: "claude-sonnet-5-5"), .luna)
    }

    func testImageRouting() {
        let img = [ChatMessage.user("look", images: [(Data([1]), "image/png")])]
        // Gemini reads images itself; text models hand image turns to the vision model.
        XCTAssertEqual(Brain.route(img, model: "gemini-auto", vision: "glm-5.3-flash").model, "gemini-auto")
        XCTAssertEqual(Brain.route(img, model: "gpt-6-luna", vision: "glm-5.3-flash").model, "glm-5.3-flash")
        XCTAssertEqual(Brain.route(img, model: "glm-5.3-flash", vision: "").images, true)
        XCTAssertEqual(Brain.route([.user("hi")], model: "gpt-6-luna", vision: "glm-5.3-flash").model, "gpt-6-luna")
    }

    func testFoldKeepsBriefingAndLatestTurn() {
        let h: [ChatMessage] = [.user("BRIEFING"), .assistant("reply 1"), .user("obs 1"), .assistant("reply 2"), .user("LATEST", images: [(Data([1]), "image/png")])]
        let f = Brain.fold(h)
        XCTAssertTrue(f.text.hasPrefix("BRIEFING"))
        XCTAssertTrue(f.text.contains("[your reply]\nreply 2"))
        XCTAssertTrue(f.text.hasSuffix("[app: latest]\nLATEST"))
        XCTAssertTrue(f.hasImage, "the newest turn's image travels with the fold")
    }

    func testLunaListPutsLunaFirst() {
        let j = JSON.parse(#"{"data": [{"id": "gpt-4o"}, {"id": "gpt-6-luna"}, {"id": "claude-haiku-5-5"}]}"#)!
        XCTAssertEqual(ModelCatalog.lunaList(j), ["gpt-6-luna", "claude-haiku-5-5", "gpt-4o"])
    }

    func testCatalogOffersOnlyTheChosenExperientialModels() {
        let exp = ModelCatalog.shared.choices.filter { $0.provider == .experiential }.map(\.id)
        XCTAssertEqual(exp, ["glm-5.3-flash-uncensored", "glm-5.3-flash", "deepseek-v4.1-flash-uncensored", "deepseek-v4.1-flash"])
    }
}
