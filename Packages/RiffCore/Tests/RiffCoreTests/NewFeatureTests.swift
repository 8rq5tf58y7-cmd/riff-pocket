import XCTest
@testable import RiffCore

private struct Echo: ChatModel {
    let reply: String
    var displayName: String { "echo" }
    var contextCharacterBudget: Int { 50_000 }
    func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String { reply }
}

final class NoteTitleTests: XCTestCase {
    func testCleanFollowsPlaudRules() {
        XCTAssertEqual(NoteTitle.clean("\"Team Meeting: Q4 Roadmap.\""), "Team Meeting Q4 Roadmap")
        XCTAssertEqual(NoteTitle.clean("Title: **Sprint Planning; Velocity**\nextra"), "Sprint Planning Velocity")
        XCTAssertNil(NoteTitle.clean("   \n  "))
        let long = NoteTitle.clean(String(repeating: "Roadmap ", count: 20))!
        XCTAssertLessThanOrEqual(long.count, 60)
        XCTAssertFalse(long.hasSuffix(" "))
    }

    func testPlaceholderDetection() {
        for t in ["2025-11-05 14:30:12", "Recording", "Phone recording Nov 5, 2025 at 9:12 AM", "plaud-abc123",
                  "20251105_143012", "", "Untitled"] {
            XCTAssertTrue(NoteTitle.isPlaceholder(t), t)
        }
        for t in ["Sprint Planning Q4 Roadmap", "Call With Dana", "Q3 Budget 2025 Review"] {
            XCTAssertFalse(NoteTitle.isPlaceholder(t), t)
        }
    }

    func testTitleUsesModelAndCleans() async throws {
        let t = try await Summarizer(model: Echo(reply: "Title: Customer Interview: Onboarding Friction."))
            .title(summary: "## Summary\nThey struggled with onboarding.", transcript: nil)
        XCTAssertEqual(t, "Customer Interview Onboarding Friction")
    }
}

final class NoteContextTests: XCTestCase {
    func testSmallMaterialIsIncludedWhole() {
        let t = Transcript(segments: [TranscriptSegment(start: 0, end: 3, text: "Kickoff for the zebra launch")])
        let ctx = NoteContext.build(question: "When?", transcript: t,
                                    documents: [NoteDocument(name: "plan.pdf", text: "Launch date: March 3")],
                                    maxCharacters: 5_000)
        XCTAssertTrue(ctx.contains("### Recording transcript"))
        XCTAssertTrue(ctx.contains("### Attachment “plan.pdf”"))
        XCTAssertTrue(ctx.contains("March 3"))
    }

    func testLargeMaterialPrefersRelevantAttachmentChunk() {
        let filler = (0..<400).map { "line \($0) about nothing in particular here" }
        let t = Transcript(segments: filler.enumerated().map {
            TranscriptSegment(start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
        })
        let doc = NoteDocument(name: "contract.pdf",
                               text: (filler.prefix(200) + ["The penalty clause is 5 percent per week"]).joined(separator: "\n"))
        let ctx = NoteContext.build(question: "What is the penalty clause?", transcript: t, documents: [doc], maxCharacters: 2_000)
        XCTAssertLessThanOrEqual(ctx.count, 2_100)
        XCTAssertTrue(ctx.contains("penalty clause is 5 percent"))
    }

    func testLibraryIncludesAttachments() {
        let n = NoteSource(id: "a", title: "Vendor call", date: Date(), transcript: nil, summary: nil,
                           documents: [NoteDocument(name: "quote.pdf", text: "Total price 12,400 dollars")])
        XCTAssertTrue(n.hasContent)
        let r = LibraryContext.build(question: "What was the total price?", notes: [n], maxCharacters: 2_000)
        XCTAssertTrue(r.text.contains("12,400"))
        XCTAssertTrue(r.text.contains("quote.pdf"))
    }
}

final class DeskTests: XCTestCase {
    private func note(_ title: String = "Recording", folder: String? = nil, summary: String? = nil,
                      updated: Double = 100) -> DeskNote {
        DeskNote(id: "N1", title: title, createdAt: Date(timeIntervalSince1970: 1),
                 updatedAt: Date(timeIntervalSince1970: updated), duration: 60, source: "plaud",
                 folderId: folder, summary: summary)
    }

    func testMergeTakesEachSidesChanges() {
        let base = note()
        let local = note(folder: "F1")                                          // phone moved it
        let remote = note("Pricing Review Q4", summary: "## Summary", updated: 200) // desk summarized + titled
        let m = DeskMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(m.folderId, "F1")
        XCTAssertEqual(m.summary, "## Summary")
        XCTAssertEqual(m.title, "Pricing Review Q4")
        XCTAssertEqual(m.updatedAt.timeIntervalSince1970, 200)
    }

    func testConflictPrefersPhoneButRealTitleBeatsPlaceholder() {
        let base = note("Old Name")
        XCTAssertEqual(DeskMerge.merge(base: base, local: note("Mine"), remote: note("Theirs")).title, "Mine")
        let m = DeskMerge.merge(base: nil, local: note("2025-11-05 14:30:12"), remote: note("Budget Call With Dana"))
        XCTAssertEqual(m.title, "Budget Call With Dana")
    }

    func testFirstSyncFillsMissingFields() {
        let m = DeskMerge.merge(base: nil, local: note(), remote: note(summary: "S"))
        XCTAssertEqual(m.summary, "S")
    }

    func testSameContentIgnoresTimestamps() {
        XCTAssertTrue(note(updated: 1).sameContent(as: note(updated: 999)))
        XCTAssertFalse(note().sameContent(as: note(folder: "X")))
    }

    func testNoteIdIsStableAndMatchesDesktop() {
        let a = NoteID.forPlaud("f_abc123")
        XCTAssertEqual(a, NoteID.forPlaud("f_abc123"))
        XCTAssertNotEqual(a, NoteID.forPlaud("f_abc124"))
        XCTAssertEqual(a.count, 36)
        XCTAssertNotNil(UUID(uuidString: a))
        // Fixed vector shared with desktop/tests/test_ids.py.
        XCTAssertEqual(NoteID.forPlaud("f_abc123"), DeskTests.vector)
    }
    static let vector = "39126D8B-41E6-57D6-B88A-2CB31BE9809F"

    func testPairingLink() {
        let p = DeskPairing.parse("riffpocket://pair?url=http://192.168.1.20:8765/&token=abcdefghijklmnop1234")
        XCTAssertEqual(p?.baseURL, "http://192.168.1.20:8765")
        XCTAssertEqual(p?.token, "abcdefghijklmnop1234")
        XCTAssertNil(DeskPairing.parse("riffpocket://pair?url=ftp://x&token=abcdefghijklmnop1234"))
        XCTAssertNil(DeskPairing.parse("https://evil.example/pair?url=http://x&token=abcdefghijklmnop1234"))
    }

    func testDeskNoteJSONUsesEpochSeconds() throws {
        let data = try DeskClient.encoder().encode(note(updated: 1_762_000_000.5))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(jsonNumber(obj["updatedAt"]), 1_762_000_000.5)
        let back = try DeskClient.decoder().decode(DeskNote.self, from: data)
        XCTAssertEqual(back.updatedAt.timeIntervalSince1970, 1_762_000_000.5)
    }
}
