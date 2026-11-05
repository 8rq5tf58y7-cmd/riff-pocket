import Foundation

public enum SummaryTemplate: String, CaseIterable, Codable, Sendable, Identifiable {
    case meeting, lecture, call, oneOnOne, general

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .meeting: return "Meeting"
        case .lecture: return "Lecture"
        case .call: return "Call"
        case .oneOnOne: return "1:1"
        case .general: return "General"
        }
    }

    public var instructions: String {
        let base = "You summarize transcripts of voice recordings. Be faithful to the transcript; never invent facts. Cite times like [00:12:34] when useful. Use Markdown."
        switch self {
        case .meeting:
            return base + " Output: ## Summary (3-5 sentences), ## Key decisions, ## Action items (owner — task — due if stated), ## Open questions."
        case .lecture:
            return base + " Output: ## Overview, ## Key concepts (bullets with short explanations), ## Definitions, ## Things to review."
        case .call:
            return base + " Output: ## Purpose, ## What was discussed, ## Commitments, ## Follow-ups."
        case .oneOnOne:
            return base + " Output: ## Highlights, ## Concerns raised, ## Feedback, ## Next steps."
        case .general:
            return base + " Output: ## Summary, ## Key points, ## Action items (if any)."
        }
    }
}

/// Chunked map-reduce summarization so small on-device models (≈4k tokens) handle hour-long recordings.
public struct Summarizer: Sendable {
    public var model: any ChatModel
    public var options: ChatOptions

    public init(model: any ChatModel, options: ChatOptions = ChatOptions()) {
        self.model = model
        self.options = options
    }

    /// Splits on segment boundaries; hard-splits any single line longer than the budget.
    public static func chunk(lines: [String], maxCharacters: Int) -> [String] {
        let budget = max(200, maxCharacters)
        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = ""
        }

        for line in lines {
            var pieces: [String] = []
            if line.count > budget {
                var rest = Substring(line)
                while !rest.isEmpty {
                    pieces.append(String(rest.prefix(budget)))
                    rest = rest.dropFirst(budget)
                }
            } else {
                pieces = [line]
            }
            for piece in pieces {
                let addition = current.isEmpty ? piece.count : piece.count + 1
                if current.count + addition > budget { flush() }
                current += current.isEmpty ? piece : "\n" + piece
            }
        }
        flush()
        return chunks
    }

    public static func chunk(_ transcript: Transcript, maxCharacters: Int) -> [String] {
        chunk(lines: transcript.timestampedLines, maxCharacters: maxCharacters)
    }

    public func summarize(_ transcript: Transcript, template: SummaryTemplate, customPrompt: String? = nil) async throws -> String {
        let instructions = customPrompt.map { template.instructions + "\nAdditional instructions: \($0)" } ?? template.instructions
        let budget = max(1_000, model.contextCharacterBudget)
        let chunks = Self.chunk(transcript, maxCharacters: budget)

        guard chunks.count > 1 else {
            return try await model.complete([.system(instructions), .user("Transcript:\n\(chunks.first ?? "")")], options: options)
        }

        // Map: dense notes per chunk.
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let note = try await model.complete([
                .system("You take dense, factual notes on part of a transcript. Keep names, numbers, decisions, tasks and [timestamps]. No preamble."),
                .user("Part \(i + 1) of \(chunks.count):\n\(chunk)"),
            ], options: options)
            notes.append(note)
        }

        // Reduce: merge notes until they fit in one request.
        while notes.joined(separator: "\n\n").count > budget && notes.count > 1 {
            let groups = Self.chunk(lines: notes, maxCharacters: budget)
            if groups.count >= notes.count { break } // cannot shrink further; let the final call truncate
            var merged: [String] = []
            for group in groups {
                merged.append(try await model.complete([
                    .system("Merge these notes into one set of dense notes. Keep every decision, task and [timestamp]. No preamble."),
                    .user(group),
                ], options: options))
            }
            notes = merged
        }

        let combined = String(notes.joined(separator: "\n\n").prefix(budget))
        return try await model.complete([
            .system(instructions),
            .user("These are notes covering the whole recording, in order:\n\(combined)"),
        ], options: options)
    }

    /// "Ask your recording": picks the most relevant chunks by word overlap when the transcript is too long.
    public func answer(_ question: String, transcript: Transcript, history: [ChatMessage] = []) async throws -> String {
        let budget = max(1_000, model.contextCharacterBudget - question.count - 500)
        let context = Self.relevantContext(question: question, transcript: transcript, maxCharacters: budget)
        var messages: [ChatMessage] = [
            .system("Answer questions about a recording using only the transcript excerpts provided. Cite [timestamps]. If the answer is not in the excerpts, say so."),
            .user("Transcript excerpts:\n\(context)"),
            .assistant("Got it. What would you like to know?"),
        ]
        messages += history.suffix(6)
        messages.append(.user(question))
        return try await model.complete(messages, options: options)
    }

    public static func relevantContext(question: String, transcript: Transcript, maxCharacters: Int) -> String {
        let small = max(400, maxCharacters / 4)
        let chunks = chunk(transcript, maxCharacters: small)
        let all = chunks.joined(separator: "\n")
        if all.count <= maxCharacters { return all }

        let terms = Set(words(question).filter { $0.count > 2 })
        let scored = chunks.enumerated().map { (index: $0.offset, text: $0.element, score: Set(words($0.element)).intersection(terms).count) }
        var picked: [(index: Int, text: String)] = []
        var used = 0
        for c in scored.sorted(by: { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }) {
            if used + c.text.count + 5 > maxCharacters { continue }
            picked.append((c.index, c.text))
            used += c.text.count + 5
        }
        return picked.sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n…\n")
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
