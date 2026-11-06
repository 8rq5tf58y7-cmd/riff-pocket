import Foundation

/// How a summary should look: format, length, tone, sections, timestamps, language, extra instructions.
/// Built-in templates are presets; users can copy and save their own.
public struct SummaryStyle: Codable, Hashable, Sendable, Identifiable {
    public enum Format: String, Codable, CaseIterable, Sendable, Identifiable {
        case bullets, paragraphs, outline, qa
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .bullets: return "Bullets"
            case .paragraphs: return "Prose"
            case .outline: return "Outline"
            case .qa: return "Q & A"
            }
        }
        var rule: String {
            switch self {
            case .bullets: return "Under each section write concise bullet points (\"- \"), one idea per bullet."
            case .paragraphs: return "Under each section write short, flowing paragraphs — no bullet lists."
            case .outline: return "Write a hierarchical outline: numbered top-level points with indented sub-bullets for detail."
            case .qa: return "Write the content as question-and-answer pairs: a bold question, then a short answer."
            }
        }
    }

    public enum Length: String, Codable, CaseIterable, Sendable, Identifiable {
        case brief, standard, detailed
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .brief: return "Brief"
            case .standard: return "Standard"
            case .detailed: return "Detailed"
            }
        }
        var rule: String {
            switch self {
            case .brief: return "Keep it brief: about 80–150 words in total. Only the essentials."
            case .standard: return "Aim for about 250–400 words in total."
            case .detailed: return "Be thorough: about 600–1,000 words, keeping important specifics, numbers and names."
            }
        }
        /// Output-token ceiling that comfortably fits the target length.
        public var maxTokens: Int {
            switch self {
            case .brief: return 500
            case .standard: return 1_200
            case .detailed: return 2_600
            }
        }
    }

    public enum Tone: String, Codable, CaseIterable, Sendable, Identifiable {
        case neutral, friendly, formal
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
        var rule: String {
            switch self {
            case .neutral: return "Use a clear, neutral tone."
            case .friendly: return "Use a warm, conversational tone."
            case .formal: return "Use a formal, professional tone suitable for sharing with stakeholders."
            }
        }
    }

    public var id: String
    public var name: String
    /// What the recording usually is, e.g. "a team meeting".
    public var context: String
    public var format: Format
    public var length: Length
    public var tone: Tone
    /// Section headings, in order. Empty = let the model choose.
    public var sections: [String]
    public var includeTimestamps: Bool
    /// Output language; empty = same language as the transcript.
    public var language: String
    public var customInstructions: String

    public init(id: String = UUID().uuidString, name: String, context: String = "a recording",
                format: Format = .bullets, length: Length = .standard, tone: Tone = .neutral,
                sections: [String] = [], includeTimestamps: Bool = true, language: String = "",
                customInstructions: String = "") {
        self.id = id
        self.name = name
        self.context = context
        self.format = format
        self.length = length
        self.tone = tone
        self.sections = sections
        self.includeTimestamps = includeTimestamps
        self.language = language
        self.customInstructions = customInstructions
    }

    public var isBuiltIn: Bool { Self.builtIn.contains { $0.id == id } }

    /// A user-editable copy with a fresh id.
    public func copy(named newName: String) -> SummaryStyle {
        var c = self
        c.id = UUID().uuidString
        c.name = newName
        return c
    }

    /// The system prompt that produces this style.
    public var instructions: String {
        var lines = [
            "You summarize the transcript of a voice recording of \(context.isEmpty ? "a recording" : context).",
            "Be faithful to the transcript; never invent facts, names or numbers.",
            length.rule,
            "Use Markdown. " + format.rule,
        ]
        let heads = sections.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if heads.isEmpty {
            lines.append("Organize with a few short '## ' headings that suit the content.")
        } else {
            lines.append("Use exactly these sections as '## ' headings, in this order: \(heads.joined(separator: ", ")). Leave out a section only if the transcript has nothing for it.")
        }
        lines.append(tone.rule)
        lines.append(includeTimestamps
            ? "Cite times like [00:12:34] after key points so the reader can jump to them."
            : "Do not include timestamps.")
        let lang = language.trimmingCharacters(in: .whitespaces)
        lines.append(lang.isEmpty ? "Write in the same language as the transcript." : "Write the summary in \(lang).")
        let extra = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append("Additional instructions from the user: \(extra)") }
        lines.append("Output only the summary, with no preamble or closing remarks.")
        return lines.joined(separator: "\n")
    }

    // MARK: Built-in templates

    public static let meeting = SummaryStyle(
        id: "builtin.meeting", name: "Meeting", context: "a meeting",
        sections: ["Summary", "Decisions", "Action items", "Open questions"],
        customInstructions: "Write action items as: owner — task — due date (if stated).")
    public static let quickRecap = SummaryStyle(
        id: "builtin.recap", name: "Quick recap", context: "a conversation",
        length: .brief, sections: ["TL;DR", "Next steps"], includeTimestamps: false)
    public static let lecture = SummaryStyle(
        id: "builtin.lecture", name: "Lecture", context: "a lecture or class", format: .outline, length: .detailed,
        sections: ["Overview", "Key concepts", "Definitions", "Examples", "To review"])
    public static let call = SummaryStyle(
        id: "builtin.call", name: "Call", context: "a phone or video call",
        sections: ["Purpose", "What was discussed", "Commitments", "Follow-ups"])
    public static let oneOnOne = SummaryStyle(
        id: "builtin.oneonone", name: "1:1", context: "a one-on-one conversation", tone: .friendly,
        sections: ["Highlights", "Concerns", "Feedback", "Next steps"])
    public static let interview = SummaryStyle(
        id: "builtin.interview", name: "Interview", context: "an interview", format: .qa,
        sections: ["Background", "Key answers", "Notable quotes", "Assessment"])
    public static let journal = SummaryStyle(
        id: "builtin.journal", name: "Voice journal", context: "a personal voice note", format: .paragraphs,
        length: .brief, tone: .friendly, sections: [], includeTimestamps: false)
    public static let detailedNotes = SummaryStyle(
        id: "builtin.detailed", name: "Detailed notes", context: "a recording", format: .outline, length: .detailed,
        sections: [])

    public static let builtIn: [SummaryStyle] = [meeting, quickRecap, lecture, call, oneOnOne, interview, journal, detailedNotes]
}

extension Summarizer {
    /// Summarize with a full style. Map-reduce keeps long recordings within small models' windows.
    public func summarize(_ transcript: Transcript, style: SummaryStyle) async throws -> String {
        var s = self
        s.options.maxTokens = max(options.maxTokens, style.length.maxTokens)
        return try await s.summarize(transcript, instructions: style.instructions)
    }
}
