import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Claude via the Anthropic Messages API (API key).
public struct AnthropicClient: ChatModel {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var displayName: String { "Anthropic: \(model)" }
    public var contextCharacterBudget: Int { 120_000 }
    private let http: HTTPClient

    public init(baseURL: String = "https://api.anthropic.com/v1", apiKey: String,
                model: String = "claude-sonnet-5-5", http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL.isEmpty ? "https://api.anthropic.com/v1" : baseURL
        self.apiKey = apiKey
        self.model = model
        self.http = http
    }

    private struct Body: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        let model: String
        let max_tokens: Int
        let system: String?
        let temperature: Double?
        let messages: [Msg]
    }

    private struct Response: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        let content: [Block]
    }

    private struct ModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    public func listModels() async throws -> [String] {
        var req = URLRequest(url: try makeURL(baseURL, "models?limit=100"))
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return try await http.sendJSON(req, as: ModelsResponse.self).data.map(\.id)
    }

    public func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let turns = messages.filter { $0.role != .system }.map { Body.Msg(role: $0.role.rawValue, content: $0.content) }

        var req = URLRequest(url: try makeURL(baseURL, "messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONEncoder().encode(Body(
            model: model,
            max_tokens: options.maxTokens,
            system: system.isEmpty ? nil : system,
            temperature: options.temperature,
            messages: turns
        ))
        let resp = try await http.sendJSON(req, as: Response.self)
        return resp.content.filter { $0.type == "text" }.compactMap(\.text).joined()
    }
}
