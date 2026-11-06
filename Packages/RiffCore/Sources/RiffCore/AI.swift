import Foundation

public struct ChatMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ s: String) -> ChatMessage { .init(.system, s) }
    public static func user(_ s: String) -> ChatMessage { .init(.user, s) }
    public static func assistant(_ s: String) -> ChatMessage { .init(.assistant, s) }
}

public struct ChatOptions: Sendable {
    public var temperature: Double?
    public var maxTokens: Int

    public init(temperature: Double? = 0.3, maxTokens: Int = 1024) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// Anything that can answer a chat: Apple Foundation Models, MLX, Ollama, OpenAI-compatible, Anthropic…
public protocol ChatModel: Sendable {
    var displayName: String { get }
    /// Roughly how many characters of transcript fit in one request (leaving room for the answer).
    /// Small on-device models get small budgets; the Summarizer chunks accordingly.
    var contextCharacterBudget: Int { get }
    func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String
}

/// Anything that turns an audio file into a transcript: WhisperKit, SpeechAnalyzer, OpenAI/Groq Whisper…
public protocol Transcriber: Sendable {
    var displayName: String { get }
    func transcribe(fileURL: URL, language: String?) async throws -> Transcript
}

// MARK: - Provider configuration

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case appleOnDevice      // Foundation Models (chat) / SpeechAnalyzer (transcribe)
    case mlx                // open-weight LLMs running on the iPhone (MLX, Hugging Face downloads)
    case whisperKit         // on-device Whisper on the Neural Engine
    case ollama             // your own machine, OpenAI-compatible endpoint
    case openAICompatible   // OpenAI, Groq, Together, LM Studio, … (API key)
    case anthropic          // Claude (API key)
    case openRouter         // sign in with OpenRouter (OAuth PKCE) or key
    case riffado            // let your Riffado server do it

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .appleOnDevice: return "Apple on-device"
        case .mlx: return "Local model (on iPhone)"
        case .whisperKit: return "WhisperKit (on-device)"
        case .ollama: return "Ollama"
        case .openAICompatible: return "OpenAI-compatible (API key)"
        case .anthropic: return "Anthropic (API key)"
        case .openRouter: return "OpenRouter (sign in)"
        case .riffado: return "Riffado server"
        }
    }

    public var canTranscribe: Bool {
        switch self {
        case .appleOnDevice, .whisperKit, .openAICompatible, .ollama, .riffado: return true
        case .anthropic, .openRouter, .mlx: return false
        }
    }

    public var canChat: Bool { self != .whisperKit }

    public var needsBaseURL: Bool {
        switch self {
        case .ollama, .openAICompatible, .riffado: return true
        default: return false
        }
    }

    public var needsAPIKey: Bool {
        switch self {
        case .openAICompatible, .anthropic, .openRouter: return true
        default: return false
        }
    }
}

public struct ProviderConfig: Codable, Hashable, Sendable {
    public var kind: ProviderKind
    public var baseURL: String
    public var model: String

    public init(kind: ProviderKind, baseURL: String = "", model: String) {
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
    }

    /// Sensible defaults when the user switches provider kind.
    public static func preset(_ kind: ProviderKind, forTranscription: Bool = false) -> ProviderConfig {
        switch kind {
        case .appleOnDevice:
            return .init(kind: kind, model: "system")
        case .mlx:
            return .init(kind: kind, model: "mlx-community/Qwen3-1.7B-4bit")
        case .whisperKit:
            return .init(kind: kind, model: "base")
        case .ollama:
            // Reach Ollama on your PC/Mac over Tailscale, e.g. https://my-mac.tailnet.ts.net
            return .init(kind: kind, baseURL: "http://localhost:11434/v1", model: forTranscription ? "whisper" : "llama3.2")
        case .openAICompatible:
            return .init(kind: kind, baseURL: "https://api.openai.com/v1", model: forTranscription ? "whisper-1" : "gpt-4o-mini")
        case .anthropic:
            return .init(kind: kind, baseURL: "https://api.anthropic.com/v1", model: "claude-opus-5-5")
        case .openRouter:
            return .init(kind: kind, baseURL: "https://openrouter.ai/api/v1", model: "openrouter/auto")
        case .riffado:
            return .init(kind: kind, baseURL: "", model: "")
        }
    }
}
