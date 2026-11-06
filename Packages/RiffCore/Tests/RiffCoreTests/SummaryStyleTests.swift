import XCTest
@testable import RiffCore

private final class LastCall: @unchecked Sendable {
    var system = ""
    var maxTokens = 0
}

private struct Capture: ChatModel {
    let box: LastCall
    var displayName: String { "capture" }
    var contextCharacterBudget: Int { 100_000 }
    func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
        box.system = messages.first { $0.role == .system }?.content ?? ""
        box.maxTokens = options.maxTokens
        return "ok"
    }
}

final class SummaryStyleTests: XCTestCase {
    func testInstructionsReflectEveryOption() {
        var s = SummaryStyle(name: "Mine", context: "a sales call", format: .qa, length: .brief, tone: .formal,
                             sections: ["Needs", " ", "Pricing"], includeTimestamps: false,
                             language: "Spanish", customInstructions: "Mention competitors.")
        let text = s.instructions
        XCTAssertTrue(text.contains("a sales call"))
        XCTAssertTrue(text.contains("question-and-answer"))
        XCTAssertTrue(text.contains("80–150 words"))
        XCTAssertTrue(text.contains("formal"))
        XCTAssertTrue(text.contains("in this order: Needs, Pricing"))
        XCTAssertTrue(text.contains("Do not include timestamps"))
        XCTAssertTrue(text.contains("in Spanish"))
        XCTAssertTrue(text.contains("Mention competitors."))

        s.sections = []
        s.language = ""
        s.includeTimestamps = true
        XCTAssertTrue(s.instructions.contains("headings that suit the content"))
        XCTAssertTrue(s.instructions.contains("same language as the transcript"))
        XCTAssertTrue(s.instructions.contains("[00:12:34]"))
    }

    func testBuiltInsAreUniqueAndCopiesAreNotBuiltIn() {
        XCTAssertEqual(Set(SummaryStyle.builtIn.map(\.id)).count, SummaryStyle.builtIn.count)
        XCTAssertTrue(SummaryStyle.meeting.isBuiltIn)
        let mine = SummaryStyle.meeting.copy(named: "Team sync")
        XCTAssertFalse(mine.isBuiltIn)
        XCTAssertEqual(mine.sections, SummaryStyle.meeting.sections)
        XCTAssertEqual(mine.name, "Team sync")
    }

    func testStyleRoundTripsAndDrivesTheRequest() async throws {
        let data = try JSONEncoder().encode(SummaryStyle.lecture)
        XCTAssertEqual(try JSONDecoder().decode(SummaryStyle.self, from: data), SummaryStyle.lecture)

        let box = LastCall()
        let t = Transcript(segments: [TranscriptSegment(start: 0, end: 5, text: "Photosynthesis converts light.")])
        _ = try await Summarizer(model: Capture(box: box)).summarize(t, style: .lecture)
        XCTAssertEqual(box.system, SummaryStyle.lecture.instructions)
        XCTAssertEqual(box.maxTokens, SummaryStyle.Length.detailed.maxTokens)
    }
}
