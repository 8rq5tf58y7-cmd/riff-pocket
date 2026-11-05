import Foundation
import RiffCore

enum AIRouterError: LocalizedError {
    case unsupported(String)
    case missingKey(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .missingKey(let s): return "Add an API key for \(s) in Settings."
        }
    }
}

/// Builds the right Transcriber / ChatModel for whatever the user picked per task.
enum AIRouter {
    static let openRouterKey = "apikey.openrouter"

    static func apiKey(for kind: ProviderKind, task: AITask) -> String? {
        kind == .openRouter ? Keychain.string(openRouterKey) : Keychain.string(task.keychainKey)
    }

    static func transcriber(for c: ProviderConfig) throws -> any Transcriber {
        switch c.kind {
        case .whisperKit:
            return WhisperKitTranscriber(model: c.model.isEmpty ? "base" : c.model)
        case .ollama, .openAICompatible:
            let key = apiKey(for: c.kind, task: .transcribe)
            if c.kind == .openAICompatible && (key ?? "").isEmpty { throw AIRouterError.missingKey(c.kind.label) }
            return OpenAICompatibleClient(config: c, apiKey: key)
        case .appleOnDevice:
            throw AIRouterError.unsupported("Apple SpeechAnalyzer transcription is planned — use WhisperKit for now.")
        case .anthropic, .openRouter:
            throw AIRouterError.unsupported("\(c.kind.label) can't transcribe audio. Pick WhisperKit or an OpenAI-compatible Whisper.")
        case .riffado:
            throw AIRouterError.unsupported("Transcription via Riffado is planned.")
        }
    }

    static func chatModel(for c: ProviderConfig, task: AITask) throws -> any ChatModel {
        switch c.kind {
        case .appleOnDevice:
            return AppleFoundationChatModel()
        case .ollama, .openAICompatible, .openRouter:
            let key = apiKey(for: c.kind, task: task)
            if c.kind != .ollama && (key ?? "").isEmpty { throw AIRouterError.missingKey(c.kind.label) }
            return OpenAICompatibleClient(config: c, apiKey: key)
        case .anthropic:
            guard let key = apiKey(for: c.kind, task: task), !key.isEmpty else { throw AIRouterError.missingKey("Anthropic") }
            return AnthropicClient(baseURL: c.baseURL, apiKey: key, model: c.model)
        case .whisperKit:
            throw AIRouterError.unsupported("WhisperKit only transcribes. Pick a chat model.")
        case .riffado:
            throw AIRouterError.unsupported("Summaries via Riffado are planned.")
        }
    }
}
