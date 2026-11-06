import XCTest
@testable import RiffCore

final class OllamaClientTests: XCTestCase {
    func testHostNormalization() {
        XCTAssertEqual(OllamaClient.normalizeHost("http://pc:11434/v1/"), "http://pc:11434")
        XCTAssertEqual(OllamaClient.normalizeHost("https://my-pc.tailnet.ts.net/api"), "https://my-pc.tailnet.ts.net")
        XCTAssertEqual(OllamaClient.normalizeHost("https://ollama.com"), "https://ollama.com")
        XCTAssertEqual(OllamaClient.normalizeHost("  "), "http://localhost:11434")
    }

    func testCloudConfigUsesOllamaComAndKey() {
        let c = OllamaClient(config: .preset(.ollamaCloud), apiKey: "k")
        XCTAssertEqual(c.host, "https://ollama.com")
        XCTAssertEqual(c.apiKey, "k")
        XCTAssertGreaterThan(c.contextCharacterBudget, 8_000)
        // A stale base URL on the config never redirects cloud calls elsewhere.
        var cfg = ProviderConfig.preset(.ollamaCloud)
        cfg.baseURL = "http://elsewhere:1"
        XCTAssertEqual(OllamaClient(config: cfg, apiKey: nil).host, "https://ollama.com")
    }

    func testProviderKinds() {
        XCTAssertTrue(ProviderKind.ollamaCloud.needsAPIKey)
        XCTAssertFalse(ProviderKind.ollamaCloud.needsBaseURL)
        XCTAssertFalse(ProviderKind.ollama.canTranscribe)
        XCTAssertTrue(ProviderKind.openRouter.needsAPIKey)
        XCTAssertEqual(ProviderKind.ollamaCloud.keychainKey, "apikey.ollamaCloud")
    }

    func testChatBodyIsNonStreaming() throws {
        let body = OllamaClient.ChatBody(model: "gemma4:31b", messages: [.init(role: "user", content: "Hi")],
                                         stream: false, options: .init(num_predict: 800, temperature: 0.3))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        XCTAssertEqual(obj["stream"] as? Bool, false)
        XCTAssertEqual((obj["options"] as? [String: Any])?["num_predict"] as? Int, 800)
    }

    func testStripsThinking() {
        XCTAssertEqual(OllamaClient.stripThinking("<think>hmm</think>\nAnswer"), "Answer")
        XCTAssertEqual(OllamaClient.stripThinking("Answer"), "Answer")
    }
}
