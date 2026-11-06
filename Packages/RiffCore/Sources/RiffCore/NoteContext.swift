import Foundation

/// Text extracted from a file attached to a note (PDF, document, photo OCR…).
public struct NoteDocument: Codable, Hashable, Sendable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

/// Builds the context for "Ask" on one note: the recording plus its attachments.
/// When everything fits, everything is sent; otherwise the most relevant chunks win.
public enum NoteContext {
    public static func build(question: String, transcript: Transcript?, documents: [NoteDocument],
                             maxCharacters: Int) -> String {
        let budget = max(500, maxCharacters)
        let recording = transcript.map { $0.timestampedLines.joined(separator: "\n") } ?? ""
        let docs = documents.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        func section(_ title: String, _ body: String) -> String { "### \(title)\n\(body)" }
        var full: [String] = []
        if !recording.isEmpty { full.append(section("Recording transcript", recording)) }
        for d in docs { full.append(section("Attachment “\(d.name)”", d.text)) }
        let all = full.joined(separator: "\n\n")
        if all.count <= budget { return all }

        // Too long: score chunks from every source by keyword overlap.
        let terms = Set(Summarizer.words(question).filter { $0.count > 2 && !LibraryContext.stopWords.contains($0) })
        struct Piece { let source: Int; let order: Int; let text: String; let score: Int }
        var titles: [String] = []
        var pieces: [Piece] = []
        let chunkSize = max(300, budget / 6)

        func add(_ title: String, _ chunks: [String]) {
            let idx = titles.count
            titles.append(title)
            for (i, c) in chunks.enumerated() {
                pieces.append(Piece(source: idx, order: i, text: c,
                                    score: Set(Summarizer.words(c)).intersection(terms).count))
            }
        }
        if let t = transcript, !t.segments.isEmpty {
            add("Recording transcript", Summarizer.chunk(t, maxCharacters: chunkSize))
        }
        for d in docs {
            let paragraphs = d.text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            add("Attachment “\(d.name)”", Summarizer.chunk(lines: paragraphs, maxCharacters: chunkSize))
        }

        // Rank; ties keep the opening of each source (useful for broad questions).
        let ranked = pieces.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.order != b.order { return a.order < b.order }
            return a.source < b.source
        }
        var picked: [Piece] = []
        var headed = Set<Int>()
        var used = 0
        for p in ranked {
            let cost = p.text.count + 1 + (headed.contains(p.source) ? 0 : titles[p.source].count + 8)
            if used + cost > budget { continue }
            picked.append(p)
            headed.insert(p.source)
            used += cost
        }
        let grouped = Dictionary(grouping: picked, by: \.source)
        return grouped.keys.sorted().map { s in
            section(titles[s], grouped[s]!.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n…\n"))
        }.joined(separator: "\n\n")
    }
}

extension Summarizer {
    /// "Ask" for one note, including its attachments.
    public func answer(_ question: String, transcript: Transcript?, documents: [NoteDocument],
                       history: [ChatMessage] = []) async throws -> String {
        let budget = max(1_000, model.contextCharacterBudget - question.count - 700)
        let context = NoteContext.build(question: question, transcript: transcript, documents: documents, maxCharacters: budget)
        var messages: [ChatMessage] = [
            .system("""
            Answer questions about a recorded note using only the material provided: the recording's transcript \
            and any attached files. Cite [timestamps] for the recording and the file name for attachments. \
            If the answer isn't in the material, say so.
            """),
            .user("Material:\n\(context)"),
            .assistant("Got it. What would you like to know?"),
        ]
        messages += history.suffix(6)
        messages.append(.user(question))
        return try await model.complete(messages, options: options)
    }
}
