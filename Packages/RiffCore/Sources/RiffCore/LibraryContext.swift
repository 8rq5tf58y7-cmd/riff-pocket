import Foundation

/// One recording as seen by Library chat.
public struct NoteSource: Sendable, Hashable {
    public var id: String
    public var title: String
    public var date: Date
    public var transcript: Transcript?
    public var summary: String?
    /// Text of files attached to the note.
    public var documents: [NoteDocument]

    public init(id: String, title: String, date: Date, transcript: Transcript?, summary: String?,
                documents: [NoteDocument] = []) {
        self.id = id
        self.title = title
        self.date = date
        self.transcript = transcript
        self.summary = summary
        self.documents = documents
    }

    public var hasContent: Bool {
        !(transcript?.segments.isEmpty ?? true) || !(summary ?? "").isEmpty
            || documents.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Picks the most relevant excerpts from many notes so they fit one model request.
///
/// Scoring is keyword overlap with the question. Summaries get a small bonus so broad
/// questions ("what did I work on this week?") see every note's summary first; ties go
/// to the most recent notes. Output is grouped per note under `### Title — date`.
public enum LibraryContext {
    public struct Result: Sendable {
        public var text: String
        public var usedNoteIds: [String]
    }

    static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "when", "where", "who", "why", "how",
        "did", "does", "about", "with", "that", "this", "from", "have", "has", "had", "you", "your",
        "all", "any", "can", "could", "would", "should", "into", "notes", "note", "recording", "recordings",
    ]

    public static func dateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func build(question: String, notes: [NoteSource], maxCharacters: Int) -> Result {
        let budget = max(500, maxCharacters)
        let terms = Set(Summarizer.words(question).filter { $0.count > 2 && !stopWords.contains($0) })
        let chunkSize = max(300, budget / 8)

        struct Piece {
            let note: Int
            let order: Int
            let text: String
            let score: Double
        }

        func score(_ text: String) -> Double {
            guard !terms.isEmpty else { return 0 }
            return Double(Set(Summarizer.words(text)).intersection(terms).count)
        }

        var pieces: [Piece] = []
        for (i, note) in notes.enumerated() where note.hasContent {
            if let s = note.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                let text = "Summary: " + String(s.prefix(chunkSize))
                pieces.append(Piece(note: i, order: -1, text: text, score: score(s) + 0.5))
            }
            if let t = note.transcript {
                for (j, chunk) in Summarizer.chunk(t, maxCharacters: chunkSize).enumerated() {
                    pieces.append(Piece(note: i, order: j, text: chunk, score: score(chunk)))
                }
            }
            for (d, doc) in note.documents.enumerated() {
                let lines = doc.text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                for (j, chunk) in Summarizer.chunk(lines: lines, maxCharacters: chunkSize).enumerated() {
                    pieces.append(Piece(note: i, order: 10_000 * (d + 1) + j,
                                        text: "From attachment “\(doc.name)”: \(chunk)", score: score(chunk)))
                }
            }
        }

        let ranked = pieces.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if notes[a.note].date != notes[b.note].date { return notes[a.note].date > notes[b.note].date }
            return a.order < b.order
        }

        func header(_ i: Int) -> String { "### \(notes[i].title) — \(dateLabel(notes[i].date))\n" }

        var picked: [Piece] = []
        var notesWithHeader = Set<Int>()
        var used = 0
        for p in ranked {
            let headerCost = notesWithHeader.contains(p.note) ? 0 : header(p.note).count + 2
            let cost = p.text.count + 1 + headerCost
            if used + cost > budget { continue }
            picked.append(p)
            notesWithHeader.insert(p.note)
            used += cost
        }

        // Group by note (oldest → newest), excerpts in original order.
        let grouped = Dictionary(grouping: picked, by: \.note)
        let noteOrder = grouped.keys.sorted { notes[$0].date < notes[$1].date }
        let text = noteOrder.map { i in
            header(i) + grouped[i]!.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n")
        }.joined(separator: "\n\n")
        return Result(text: text, usedNoteIds: noteOrder.map { notes[$0].id })
    }
}

extension Summarizer {
    /// Library chat: answer across many notes (all of them, or one folder).
    public func answer(_ question: String, library notes: [NoteSource], history: [ChatMessage] = []) async throws -> String {
        let usable = notes.filter(\.hasContent)
        guard !usable.isEmpty else {
            return "None of these notes have a transcript or summary yet. Transcribe some recordings first."
        }
        let budget = max(1_000, model.contextCharacterBudget - question.count - 900)
        let context = LibraryContext.build(question: question, notes: usable, maxCharacters: budget)
        var messages: [ChatMessage] = [
            .system("""
            You answer questions about the user's recorded notes. You are given excerpts from \(usable.count) \
            recordings, each under a '### Title — date' heading; you may only see the most relevant parts. \
            Use only these excerpts. Cite the note title (and [timestamps] when present). If the answer isn't \
            in the excerpts, say so and suggest which note might contain it.
            """),
            .user("Excerpts:\n\(context.text)"),
            .assistant("Got it. What would you like to know about your notes?"),
        ]
        messages += history.suffix(6)
        messages.append(.user(question))
        return try await model.complete(messages, options: options)
    }
}
