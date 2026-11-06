import XCTest
@testable import RiffCore

private func note(_ id: String, _ title: String, daysAgo: Double, lines: [String], summary: String? = nil) -> NoteSource {
    NoteSource(
        id: id, title: title,
        date: Date(timeIntervalSince1970: 1_760_000_000 - daysAgo * 86_400),
        transcript: Transcript(segments: lines.enumerated().map {
            TranscriptSegment(start: Double($0.offset * 30), end: Double($0.offset * 30 + 29), text: $0.element)
        }),
        summary: summary
    )
}

private func filler(_ n: Int, tag: String) -> [String] {
    (0..<n).map { i in (0..<18).map { "\(tag)\(i)w\($0)" }.joined(separator: " ") }
}

final class LibraryContextTests: XCTestCase {
    func testFindsRelevantNoteAmongMany() {
        var notes = (0..<30).map { note("n\($0)", "Meeting \($0)", daysAgo: Double($0), lines: filler(40, tag: "x\($0)")) }
        notes[17] = note("budget", "Finance sync", daysAgo: 17,
                         lines: filler(10, tag: "y") + ["We agreed the marketing budget is forty thousand dollars"] + filler(10, tag: "z"))
        let r = LibraryContext.build(question: "What is the marketing budget?", notes: notes, maxCharacters: 3_000)
        XCTAssertLessThanOrEqual(r.text.count, 3_000)
        XCTAssertTrue(r.text.contains("forty thousand"))
        XCTAssertTrue(r.text.contains("### Finance sync"))
        XCTAssertEqual(r.usedNoteIds.first.map { $0 == "budget" || r.usedNoteIds.contains("budget") }, true)
    }

    func testBroadQuestionPrefersSummariesOfRecentNotes() {
        let notes = (0..<10).map {
            note("n\($0)", "Day \($0)", daysAgo: Double($0), lines: filler(30, tag: "q\($0)"), summary: "Summary of day \($0).")
        }
        let r = LibraryContext.build(question: "What happened?", notes: notes, maxCharacters: 1_200)
        XCTAssertTrue(r.text.contains("Summary of day 0."))
        XCTAssertTrue(r.text.contains("Summary of day 1."))
        // Grouped oldest → newest.
        let i1 = r.text.range(of: "### Day 1")!.lowerBound
        let i0 = r.text.range(of: "### Day 0")!.lowerBound
        XCTAssertLessThan(i1, i0)
    }

    func testSkipsNotesWithoutContent() {
        let empty = NoteSource(id: "e", title: "Empty", date: Date(), transcript: nil, summary: nil)
        let r = LibraryContext.build(question: "anything", notes: [empty, note("a", "A", daysAgo: 1, lines: ["hello world"])],
                                     maxCharacters: 2_000)
        XCTAssertEqual(r.usedNoteIds, ["a"])
    }

    func testLibraryAnswerSendsExcerpts() async throws {
        struct Echo: ChatModel {
            var displayName: String { "echo" }
            var contextCharacterBudget: Int { 4_000 }
            func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
                messages[1].content
            }
        }
        let notes = [note("a", "Kickoff", daysAgo: 2, lines: ["The launch date is March 3"])]
        let out = try await Summarizer(model: Echo()).answer("When is the launch?", library: notes)
        XCTAssertTrue(out.contains("### Kickoff"))
        XCTAssertTrue(out.contains("March 3"))
    }
}
