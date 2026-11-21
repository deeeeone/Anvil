import XCTest
@testable import Anvil

final class ChatGPTProviderTests: XCTestCase {
    func testRoutesChatGPTModels() {
        XCTAssertEqual(Providers.provider(for: "chatgpt/auto"), .chatgpt)
        XCTAssertEqual(Providers.provider(for: "chatgpt/gpt-5.5-thinking"), .chatgpt)
        XCTAssertNotEqual(Providers.provider(for: "gemini-auto"), .chatgpt)
    }

    func testModelListKeepsOnlyChatGPTWithAutoFirst() {
        let j = JSON.parse(#"{"data":[{"id":"glm-5"},{"id":"chatgpt/o3"},{"id":"chatgpt/auto"},{"id":"chatgpt/gpt-5.5"}]}"#)!
        XCTAssertEqual(ModelCatalog.chatgptList(j), ["chatgpt/auto", "chatgpt/gpt-5.5", "chatgpt/o3"])
    }

    func testProviderIsKeyless() {
        XCTAssertEqual(Provider.chatgpt.label, "ChatGPT (web)")
        XCTAssertTrue(Providers.defaultChatGPTModels.allSatisfy { $0.hasPrefix("chatgpt/") })
    }
}
