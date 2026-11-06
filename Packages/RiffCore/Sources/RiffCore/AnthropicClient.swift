import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude via the Anthropic Messages API (raw HTTP; Swift has no official SDK).
///
/// Current request rules (API version 2026-10-21):
/// - No `temperature` / `top_p` / `top_k` — removed on current models (400 if sent).
/// - Thinking is adaptive / always on for current models and counts toward `max_tokens`,
///   so the cap is kept generous (~16k for non-streaming calls) to avoid truncated answers.
/// - Refusals come back as HTTP 200 with `stop_reason: "refusal"`; current models get the
///   server-side refusal fallback (`fallbacks: "default"`).
public struct AnthropicClient: ChatModel {
    public static let apiVersion = "2026-10-21"
    public static let defaultModel = "claude-opus-5-5"
    /// Non-streaming ceiling that leaves room for adaptive thinking plus the answer.
    public static let minMaxTokens = 16_000
    /// Models that accept the server-side refusal fallback (`fallbacks: "default"`).
    static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    public enum Failure: Error, CustomStringConvertible {
        case refused(category: String?, explanation: String?)
        case empty(stopReason: String?)

        public var description: String {
            switch self {
            case .refused(let category, let explanation):
                return "Claude declined this request" + (category.map { " (\($0))" } ?? "") + (explanation.map { ": \($0)" } ?? ".")
            case .empty(let stop):
                return "Claude returned no text" + (stop.map { " (stop reason: \($0))" } ?? "") + "."
            }
        }
    }

    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var displayName: String { "Anthropic: \(model)" }
    public var contextCharacterBudget: Int { 120_000 }
    private let http: HTTPClient

    public init(baseURL: String = "https://api.anthropic.com/v1", apiKey: String,
                model: String = AnthropicClient.defaultModel, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL.isEmpty ? "https://api.anthropic.com/v1" : baseURL
        self.apiKey = apiKey
        self.model = model.isEmpty ? AnthropicClient.defaultModel : model
        self.http = http
    }

    struct Body: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        let model: String
        let max_tokens: Int
        let system: String?
        let messages: [Msg]
        let fallbacks: String?
    }

    private struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct StopDetails: Decodable { let category: String?; let explanation: String? }
        let content: [Block]?
        let stop_reason: String?
        let stop_details: StopDetails?
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private func headers(_ req: inout URLRequest) {
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
    }

    public func listModels() async throws -> [String] {
        var req = URLRequest(url: try makeURL(baseURL, "models?limit=100"))
        headers(&req)
        return try await http.sendJSON(req, as: ModelsResponse.self).data.map(\.id)
    }

    /// The request body — no sampling parameters; `options.temperature` is intentionally ignored.
    static func body(model: String, messages: [ChatMessage], options: ChatOptions) -> Body {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }.map { Body.Msg(role: $0.role.rawValue, content: $0.content) }
        return Body(
            model: model,
            max_tokens: max(options.maxTokens, minMaxTokens),
            system: system.isEmpty ? nil : system,
            messages: turns,
            fallbacks: fallbackModels.contains(model) ? "default" : nil
        )
    }

    public func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
        let body = Self.body(model: model, messages: messages, options: options)
        var req = URLRequest(url: try makeURL(baseURL, "messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers(&req)
        if body.fallbacks != nil { req.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONEncoder().encode(body)

        let resp = try await http.sendJSON(req, as: Response.self)
        if resp.stop_reason == "refusal" {
            throw Failure.refused(category: resp.stop_details?.category, explanation: resp.stop_details?.explanation)
        }
        // Thinking blocks (empty by default) precede the answer; keep only text.
        let text = (resp.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.empty(stopReason: resp.stop_reason)
        }
        return text
    }
}
