import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Chat + transcription against any OpenAI-compatible server:
/// OpenAI, Groq, Together, OpenRouter, LM Studio, and Ollama (`http://host:11434/v1`).
public struct OpenAICompatibleClient: ChatModel, Transcriber {
    public var baseURL: String
    public var apiKey: String?
    public var model: String
    public var displayName: String
    public var contextCharacterBudget: Int
    public var extraHeaders: [String: String]
    private let http: HTTPClient

    public init(
        baseURL: String,
        apiKey: String?,
        model: String,
        displayName: String? = nil,
        contextCharacterBudget: Int = 24_000,
        extraHeaders: [String: String] = [:],
        http: HTTPClient = HTTPClient()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.displayName = displayName ?? "\(model) @ \(baseURL)"
        self.contextCharacterBudget = contextCharacterBudget
        self.extraHeaders = extraHeaders
        self.http = http
    }

    public init(config: ProviderConfig, apiKey: String?) {
        var headers: [String: String] = [:]
        if config.kind == .openRouter {
            headers["X-Title"] = "Riff Pocket"
        }
        // Local Ollama models usually run with small context windows by default.
        let budget = config.kind == .ollama ? 8_000 : 24_000
        self.init(baseURL: config.baseURL, apiKey: apiKey, model: config.model,
                  displayName: "\(config.kind.label): \(config.model)",
                  contextCharacterBudget: budget, extraHeaders: headers)
    }

    private func authorize(_ req: inout URLRequest) {
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
    }

    // MARK: Chat

    private struct ChatBody: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Msg]
        let temperature: Double?
        let max_tokens: Int
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    public func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
        var req = URLRequest(url: try makeURL(baseURL, "chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        authorize(&req)
        let body = ChatBody(
            model: model,
            messages: messages.map { .init(role: $0.role.rawValue, content: $0.content) },
            temperature: options.temperature,
            max_tokens: options.maxTokens
        )
        req.httpBody = try JSONEncoder().encode(body)
        let resp = try await http.sendJSON(req, as: ChatResponse.self)
        return resp.choices.first?.message.content ?? ""
    }

    // MARK: Transcription

    private struct TranscriptionResponse: Decodable {
        struct Seg: Decodable { let start: Double; let end: Double; let text: String }
        let text: String?
        let language: String?
        let segments: [Seg]?
    }

    public func transcribe(fileURL: URL, language: String?) async throws -> Transcript {
        let audio = try Data(contentsOf: fileURL)
        var form = MultipartForm()
        form.addField("model", model)
        form.addField("response_format", "verbose_json")
        form.addField("timestamp_granularities[]", "segment")
        if let language = language { form.addField("language", language) }
        form.addFile("file", filename: fileURL.lastPathComponent,
                     mimeType: audioMimeType(forExtension: fileURL.pathExtension), data: audio)

        var req = URLRequest(url: try makeURL(baseURL, "audio/transcriptions"))
        req.httpMethod = "POST"
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 900
        authorize(&req)
        req.httpBody = form.finalized()

        let resp = try await http.sendJSON(req, as: TranscriptionResponse.self)
        if let segs = resp.segments, !segs.isEmpty {
            return Transcript(language: resp.language,
                              segments: segs.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.text) })
        }
        return Transcript(language: resp.language,
                          segments: [TranscriptSegment(start: 0, end: 0, text: resp.text ?? "")])
    }
}
