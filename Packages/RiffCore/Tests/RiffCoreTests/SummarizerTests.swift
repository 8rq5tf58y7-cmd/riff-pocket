import XCTest
@testable import RiffCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _n = 0
    var n: Int { lock.lock(); defer { lock.unlock() }; return _n }
    func bump() { lock.lock(); _n += 1; lock.unlock() }
}

private struct FakeModel: ChatModel {
    let budget: Int
    let counter: Counter
    var displayName: String { "fake" }
    var contextCharacterBudget: Int { budget }
    func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
        counter.bump()
        return "NOTE(\(messages.last?.content.count ?? 0))"
    }
}

private func transcript(lines: Int, wordsPerLine: Int = 20) -> Transcript {
    Transcript(segments: (0..<lines).map { i in
        TranscriptSegment(start: Double(i * 10), end: Double(i * 10 + 9),
                          text: (0..<wordsPerLine).map { "w\(i)x\($0)" }.joined(separator: " "))
    })
}

final class SummarizerTests: XCTestCase {
    func testClockFormatting() {
        XCTAssertEqual(Transcript.clock(0), "00:00:00")
        XCTAssertEqual(Transcript.clock(3725.9), "01:02:05")
    }

    func testChunksRespectBudget() {
        let t = transcript(lines: 200)
        let chunks = Summarizer.chunk(t, maxCharacters: 1_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1_000 })
        // Nothing lost.
        XCTAssertEqual(chunks.joined(separator: "\n"), t.timestampedLines.joined(separator: "\n"))
    }

    func testOverlongLineIsHardSplit() {
        let chunks = Summarizer.chunk(lines: [String(repeating: "a", count: 2_500)], maxCharacters: 1_000)
        XCTAssertEqual(chunks.map(\.count), [1_000, 1_000, 500])
    }

    func testShortTranscriptIsOneCall() async throws {
        let counter = Counter()
        let s = Summarizer(model: FakeModel(budget: 100_000, counter: counter))
        _ = try await s.summarize(transcript(lines: 5), style: .meeting)
        XCTAssertEqual(counter.n, 1)
    }

    func testLongTranscriptMapsThenReduces() async throws {
        let counter = Counter()
        let s = Summarizer(model: FakeModel(budget: 2_000, counter: counter))
        _ = try await s.summarize(transcript(lines: 300), style: .lecture)
        let chunkCount = Summarizer.chunk(transcript(lines: 300), maxCharacters: 2_000).count
        XCTAssertGreaterThanOrEqual(counter.n, chunkCount + 1)
    }

    func testRelevantContextPrefersMatchingChunk() {
        var t = transcript(lines: 400)
        t.segments[250].text = "the budget for the zebra project is forty thousand"
        let ctx = Summarizer.relevantContext(question: "What is the zebra budget?", transcript: t, maxCharacters: 2_000)
        XCTAssertTrue(ctx.contains("zebra"))
        XCTAssertLessThanOrEqual(ctx.count, 2_000)
    }

    func testProviderPresets() {
        XCTAssertEqual(ProviderConfig.preset(.ollama).baseURL, "http://localhost:11434")
        XCTAssertTrue(ProviderKind.whisperKit.canTranscribe)
        XCTAssertFalse(ProviderKind.whisperKit.canChat)
        XCTAssertFalse(ProviderKind.anthropic.canTranscribe)
        XCTAssertTrue(ProviderKind.mlx.canChat)
        XCTAssertFalse(ProviderKind.mlx.canTranscribe)
        XCTAssertFalse(ProviderKind.mlx.needsAPIKey)
        XCTAssertEqual(ProviderConfig.preset(.mlx).model, "mlx-community/Qwen3-1.7B-4bit")
    }

    func testMakeURLJoinsCleanly() throws {
        XCTAssertEqual(try makeURL("http://h:1/v1/", "/chat/completions").absoluteString, "http://h:1/v1/chat/completions")
    }
}
