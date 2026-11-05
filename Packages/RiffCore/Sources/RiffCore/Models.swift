import Foundation

/// One timed piece of a transcript.
public struct TranscriptSegment: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: String?

    public init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

public struct Transcript: Codable, Hashable, Sendable {
    public var language: String?
    public var segments: [TranscriptSegment]

    public init(language: String? = nil, segments: [TranscriptSegment]) {
        self.language = language
        self.segments = segments
    }

    /// Plain text, no timestamps.
    public var text: String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// One line per segment: `[00:01:23] Speaker: text` — what the LLM sees, so it can cite times.
    public var timestampedLines: [String] {
        segments.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let who = seg.speaker.map { "\($0): " } ?? ""
            return "[\(Transcript.clock(seg.start))] \(who)\(text)"
        }
    }

    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
