import Foundation
import RiffCore

enum AIRouterError: LocalizedError {
    case unsupported(String)
    case missingKey(String)
    case notDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .missingKey(let s): return "Add an API key for \(s) — tap the model chip or open Settings."
        case .notDownloaded(let s): return "\(s) isn't on this iPhone yet. Download it from the model picker or Settings → Local models."
        }
    }
}

/// Builds the right Transcriber / ChatModel for whatever source + model the user picked.
@MainActor
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
        case .anthropic, .openRouter, .mlx:
            throw AIRouterError.unsupported("\(c.kind.label) can't transcribe audio. Pick WhisperKit or an OpenAI-compatible Whisper.")
        case .riffado:
            throw AIRouterError.unsupported("Transcription via Riffado is planned.")
        }
    }

    static func chatModel(for c: ProviderConfig, task: AITask) throws -> any ChatModel {
        switch c.kind {
        case .appleOnDevice:
            return AppleFoundationChatModel()
        case .mlx:
            guard MLXModelStore.shared.isDownloaded(c.model) else {
                throw AIRouterError.notDownloaded(LocalModelCatalog.name(for: c.model))
            }
            return MLXChatModel(modelId: c.model)
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
            throw AIRouterError.unsupported("Chat via Riffado is planned.")
        }
    }

    /// Models a remote source offers (for the picker).
    static func listModels(for c: ProviderConfig, task: AITask) async throws -> [String] {
        let key = apiKey(for: c.kind, task: task)
        switch c.kind {
        case .anthropic:
            return try await AnthropicClient(baseURL: c.baseURL, apiKey: key ?? "", model: c.model).listModels()
        case .ollama, .openAICompatible, .openRouter:
            return try await OpenAICompatibleClient(config: c, apiKey: key).listModels()
        default:
            return []
        }
    }
}

extension ProviderKind {
    var symbol: String {
        switch self {
        case .appleOnDevice: return "apple.logo"
        case .mlx: return "cpu"
        case .whisperKit: return "waveform"
        case .ollama: return "server.rack"
        case .openAICompatible: return "key.horizontal"
        case .anthropic: return "key.horizontal"
        case .openRouter: return "person.badge.key"
        case .riffado: return "externaldrive.connected.to.line.below"
        }
    }

    var shortName: String {
        switch self {
        case .appleOnDevice: return "Apple"
        case .mlx: return "On-device"
        case .whisperKit: return "WhisperKit"
        case .ollama: return "Ollama"
        case .openAICompatible: return "API"
        case .anthropic: return "Anthropic"
        case .openRouter: return "OpenRouter"
        case .riffado: return "Riffado"
        }
    }
}

extension ProviderConfig {
    /// e.g. "On-device · Qwen3 1.7B", "Ollama · llama3.2"
    var chipLabel: String {
        switch kind {
        case .appleOnDevice: return "Apple Intelligence"
        case .mlx: return "On-device · \(LocalModelCatalog.name(for: model))"
        default:
            let m = model.split(separator: "/").last.map(String.init) ?? model
            return m.isEmpty ? kind.shortName : "\(kind.shortName) · \(m)"
        }
    }
}
