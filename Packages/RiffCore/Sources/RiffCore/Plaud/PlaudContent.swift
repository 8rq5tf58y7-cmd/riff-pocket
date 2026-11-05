// Swift port of Riffado's src/lib/plaud/content.ts (AGPL-3.0).
// Parses Plaud's own transcript/summary from GET /file/detail/{id}.
// Riffado notes the transcript segment body is not fully verified — kept defensive.
import Foundation

public enum PlaudContent {
    public struct Parsed: Sendable {
        public var transcript: Transcript?
        public var summary: String?
        public init(transcript: Transcript? = nil, summary: String? = nil) {
            self.transcript = transcript
            self.summary = summary
        }
    }

    static let transcriptTypes: Set<String> = ["transaction", "transcript"]
    static let transcriptPrefixes = ["source_transaction:"]
    static let summaryTypes: Set<String> = ["auto_sum_note", "sum_multi_note", "summary", "note", "ai_summary"]
    static let summaryPrefixes = ["auto_sum:", "sum_multi:"]

    static func matches(_ item: PlaudContentItem, _ types: Set<String>, _ prefixes: [String]) -> Bool {
        if types.contains((item.data_type ?? "").lowercased()) { return true }
        let id = item.data_id ?? ""
        return prefixes.contains { id.hasPrefix($0) }
    }

    static func isPrimarySummary(_ item: PlaudContentItem) -> Bool {
        (item.data_type ?? "").lowercased() == "auto_sum_note" || (item.data_id ?? "").hasPrefix("auto_sum:")
    }

    public static func select(_ detail: PlaudFileDetail) -> (transcript: PlaudContentItem?, summary: PlaudContentItem?) {
        var transcript: PlaudContentItem?
        var summary: PlaudContentItem?
        var fallback: PlaudContentItem?
        for item in detail.content_list ?? [] {
            if transcript == nil && matches(item, transcriptTypes, transcriptPrefixes) {
                transcript = item
            } else if matches(item, summaryTypes, summaryPrefixes) {
                if summary == nil && isPrimarySummary(item) { summary = item }
                else if fallback == nil { fallback = item }
            }
        }
        return (transcript, summary ?? fallback)
    }

    public static func isReady(_ item: PlaudContentItem?) -> Bool {
        guard let item = item else { return false }
        return item.task_status == 1 && !(item.data_link ?? "").isEmpty
    }

    /// Inline payload from `pre_download_content_list` (JSON string keyed by data_id).
    public static func inline(_ detail: PlaudFileDetail, dataId: String?) -> Any? {
        guard let dataId = dataId,
              let entry = detail.pre_download_content_list?.first(where: { $0.data_id == dataId }),
              let content = entry.data_content else { return nil }
        if let data = content.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return json
        }
        return content
    }

    public static func parseTranscript(_ raw: Any) -> Transcript {
        var array: [Any] = []
        if let a = raw as? [Any] {
            array = a
        } else if let obj = raw as? [String: Any] {
            for key in ["segments", "transcript", "data"] {
                if let a = obj[key] as? [Any], !a.isEmpty { array = a; break }
            }
        }
        let segments: [TranscriptSegment] = array.compactMap { element in
            guard let s = element as? [String: Any] else { return nil }
            let text = (s["content"] as? String) ?? (s["text"] as? String) ?? ""
            let start = jsonNumber(s["start_time"]) ?? 0
            let end = jsonNumber(s["end_time"]) ?? start
            var speaker: String?
            if let str = s["speaker"] as? String, !str.isEmpty { speaker = str }
            else if let n = jsonNumber(s["speaker"]) { speaker = "Speaker \(Int(n))" }
            // Plaud times are milliseconds.
            return TranscriptSegment(start: start / 1000, end: end / 1000, text: text, speaker: speaker)
        }
        var language: String?
        if let obj = raw as? [String: Any], let lang = obj["language"] as? String,
           !lang.trimmingCharacters(in: .whitespaces).isEmpty {
            language = lang.trimmingCharacters(in: .whitespaces)
        }
        return Transcript(language: language, segments: segments)
    }

    public static func parseSummary(_ raw: Any) -> String {
        if let s = raw as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let obj = raw as? [String: Any] else { return "" }
        var out = ((obj["ai_content"] as? String) ?? (obj["summary"] as? String) ?? (obj["content"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPoints = ((obj["key_points"] ?? obj["keyPoints"] ?? obj["highlights"]) as? [Any])?.compactMap { $0 as? String } ?? []
        let actions = ((obj["action_items"] ?? obj["actionItems"] ?? obj["todos"]) as? [Any])?.compactMap { $0 as? String } ?? []
        if !keyPoints.isEmpty { out += "\n\n## Key points\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n") }
        if !actions.isEmpty { out += "\n\n## Action items\n" + actions.map { "- \($0)" }.joined(separator: "\n") }
        return out
    }
}
