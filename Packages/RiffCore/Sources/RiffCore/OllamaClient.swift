import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Native Ollama API — works for your own Ollama server and for Ollama Cloud
/// (`https://ollama.com`, `Authorization: Bearer <OLLAMA_API_KEY>`).
///
/// - Chat: `POST {host}/api/chat` with `stream: false`
/// - Models: `GET {host}/api/tags`
public struct OllamaClient: ChatModel {
    public static let cloudHost = "https://ollama.com"

    public var host: String
    public var apiKey: String?
    public var model: String
    public var displayName: String
    public var contextCharacterBudget: Int
    private let http: HTTPClient

    public init(host: String, apiKey: String?, model: String, displayName: String? = nil,
                contextCharacterBudget: Int = 8_000, http: HTTPClient = HTTPClient()) {
        self.host = OllamaClient.normalizeHost(host)
        self.apiKey = apiKey
        self.model = model
        self.displayName = displayName ?? "Ollama: \(model)"
        self.contextCharacterBudget = contextCharacterBudget
        self.http = http
    }

    public init(config: ProviderConfig, apiKey: String?) {
        let cloud = config.kind == .ollamaCloud
        self.init(
            host: cloud ? OllamaClient.cloudHost : config.baseURL,
            apiKey: apiKey,
            model: config.model,
            displayName: "\(cloud ? "Ollama Cloud" : "Ollama"): \(config.model)",
            // Cloud models are large-context; local defaults are small unless num_ctx is raised.
            contextCharacterBudget: cloud ? 48_000 : 8_000
        )
    }

    /// Accepts "http://pc:11434", "http://pc:11434/v1" (OpenAI-style) or "…/api" and returns the bare host.
    public static func normalizeHost(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes()
        for suffix in ["/v1", "/api"] where h.hasSuffix(suffix) {
            h = String(h.dropLast(suffix.count))
        }
        return h.isEmpty ? "http://localhost:11434" : h
    }

    private func request(_ path: String) throws -> URLRequest {
        var req = URLRequest(url: try makeURL(host, path))
        if let key = apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    struct ChatBody: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        struct Options: Encodable { let num_predict: Int; let temperature: Double? }
        let model: String
        let messages: [Msg]
        let stream: Bool
        let options: Options
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let error: String?
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String? ; let model: String? }
        let models: [Model]
    }

    public func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
        var req = try request("api/chat")
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ChatBody(
            model: model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
            stream: false,
            options: .init(num_predict: options.maxTokens, temperature: options.temperature)
        ))
        let resp = try await http.sendJSON(req, as: ChatResponse.self)
        if let err = resp.error { throw HTTPError.status(200, err) }
        return OllamaClient.stripThinking(resp.message?.content ?? "")
    }

    public func listModels() async throws -> [String] {
        var req = try request("api/tags")
        req.timeoutInterval = 30
        return try await http.sendJSON(req, as: TagsResponse.self).models
            .compactMap { $0.name ?? $0.model }.sorted()
    }

    /// Reasoning models (qwen3, deepseek-r1…) may inline `<think>…</think>` before the answer.
    public static func stripThinking(_ s: String) -> String {
        var out = s
        while let open = out.range(of: "<think>") {
            if let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
