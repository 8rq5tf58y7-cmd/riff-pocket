import XCTest
@testable import RiffCore

final class AnthropicClientTests: XCTestCase {
    private func json(_ body: AnthropicClient.Body) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
    }

    func testNoSamplingParametersAreSent() throws {
        let body = AnthropicClient.body(
            model: "claude-opus-5-5",
            messages: [.system("Be brief."), .user("Hi")],
            options: ChatOptions(temperature: 0.3, maxTokens: 1024)
        )
        let obj = try json(body)
        XCTAssertNil(obj["temperature"])
        XCTAssertNil(obj["top_p"])
        XCTAssertNil(obj["top_k"])
        XCTAssertEqual(obj["system"] as? String, "Be brief.")
        XCTAssertEqual((obj["messages"] as? [[String: Any]])?.count, 1)
    }

    func testMaxTokensLeavesRoomForThinking() throws {
        let small = AnthropicClient.body(model: "claude-opus-5-5", messages: [.user("Hi")], options: ChatOptions(maxTokens: 1024))
        XCTAssertEqual(small.max_tokens, AnthropicClient.minMaxTokens)
        let big = AnthropicClient.body(model: "claude-opus-5-5", messages: [.user("Hi")], options: ChatOptions(maxTokens: 32_000))
        XCTAssertEqual(big.max_tokens, 32_000)
    }

    func testRefusalFallbackOnlyForSupportedModels() throws {
        let opus = try json(AnthropicClient.body(model: "claude-opus-5-5", messages: [.user("Hi")], options: ChatOptions()))
        XCTAssertEqual(opus["fallbacks"] as? String, "default")
        let haiku = try json(AnthropicClient.body(model: "claude-haiku-5-5", messages: [.user("Hi")], options: ChatOptions()))
        XCTAssertNil(haiku["fallbacks"])
    }

    func testDefaults() {
        XCTAssertEqual(AnthropicClient.apiVersion, "2026-10-21")
        XCTAssertEqual(ProviderConfig.preset(.anthropic).model, "claude-opus-5-5")
        XCTAssertEqual(AnthropicClient(apiKey: "k", model: "").model, "claude-opus-5-5")
    }
}
