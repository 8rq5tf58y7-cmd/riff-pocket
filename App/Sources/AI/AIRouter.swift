import Foundation
import RiffCore

enum AIRouterError: LocalizedError {
    case unsupported(String)
    case missingKey(String)
    case notDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return s
        case .missingKey(let s): return "Add an API key for \(s) — tap the model chip or open Settings → AI models."
        case .notDownloaded(let s): return "\(s) isn't on this iPhone yet. Download it from the model picker or Settings → Local models."
        }
    }
}

/// Builds the right Transcriber / ChatModel for whatever source + model the user picked.
@MainActor
enum AIRouter {
    /// One key per source, shared by every task.
    static func keychainKey(for kind: ProviderKind) -> String { kind.keychainKey }

    static func apiKey(for kind: ProviderKind, task: AITask) -> String? {
        if let k = Keychain.string(kind.keychainKey), !k.isEmpty { return k }
        // Keys saved by earlier builds: OpenRouter sign-in, or per-task keys.
        let legacy = kind == .openRouter ? Keychain.string("apikey.openrouter") : Keychain.string(task.keychainKey)
        return (legacy ?? "").isEmpty ? nil : legacy
    }

    static func setAPIKey(_ value: String?, for kind: ProviderKind) {
        Keychain.setString(value, for: kind.keychainKey)
    }

    static func transcriber(for c: ProviderConfig) throws -> any Transcriber {
        switch c.kind {
        case .whisperKit:
            return WhisperKitTranscriber(model: c.model.isEmpty ? "base" : c.model)
        case .openAICompatible:
            guard let key = apiKey(for: c.kind, task: .transcribe) else { throw AIRouterError.missingKey(c.kind.label) }
            return OpenAICompatibleClient(config: c, apiKey: key)
        case .appleOnDevice:
            throw AIRouterError.unsupported("Apple SpeechAnalyzer transcription is planned — use WhisperKit for now.")
        case .anthropic, .openRouter, .mlx, .ollama, .ollamaCloud:
            throw AIRouterError.unsupported("\(c.kind.label) can't transcribe audio. Pick WhisperKit or an OpenAI-compatible Whisper.")
        case .riffado:
            throw AIRouterError.unsupported("Transcription via Riffado is planned.")
        }
    }

    static func chatModel(for c: ProviderConfig, task: AITask) throws -> any ChatModel {
        let key = apiKey(for: c.kind, task: task)
        if c.kind.needsAPIKey && key == nil { throw AIRouterError.missingKey(c.kind.label) }
        switch c.kind {
        case .appleOnDevice:
            return AppleFoundationChatModel()
        case .mlx:
            guard MLXModelStore.shared.isDownloaded(c.model) else {
                throw AIRouterError.notDownloaded(LocalModelCatalog.name(for: c.model))
            }
            return MLXChatModel(modelId: c.model)
        case .ollama, .ollamaCloud:
            return OllamaClient(config: c, apiKey: key)
        case .openAICompatible, .openRouter:
            return OpenAICompatibleClient(config: c, apiKey: key)
        case .anthropic:
            return AnthropicClient(baseURL: c.baseURL, apiKey: key ?? "", model: c.model)
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
        case .ollama, .ollamaCloud:
            return try await OllamaClient(config: c, apiKey: key).listModels()
        case .openAICompatible, .openRouter:
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
        case .ollama: return "desktopcomputer"
        case .ollamaCloud: return "cloud"
        case .openAICompatible: return "key.horizontal"
        case .anthropic: return "key.horizontal"
        case .openRouter: return "arrow.triangle.branch"
        case .riffado: return "externaldrive.connected.to.line.below"
        }
    }

    var shortName: String {
        switch self {
        case .appleOnDevice: return "Apple"
        case .mlx: return "On-device"
        case .whisperKit: return "WhisperKit"
        case .ollama: return "Ollama"
        case .ollamaCloud: return "Ollama Cloud"
        case .openAICompatible: return "API"
        case .anthropic: return "Anthropic"
        case .openRouter: return "OpenRouter"
        case .riffado: return "Riffado"
        }
    }

    var blurb: String {
        switch self {
        case .appleOnDevice: return "Built into iOS · private · free"
        case .mlx: return "Open models running on this iPhone"
        case .whisperKit: return "Whisper on the Neural Engine"
        case .ollama: return "Your own computer, over your network"
        case .ollamaCloud: return "Big open models hosted by ollama.com"
        case .openAICompatible: return "OpenAI, Groq, Together, LM Studio…"
        case .anthropic: return "Claude models with your API key"
        case .openRouter: return "Hundreds of models · API key or sign in"
        case .riffado: return "Your Riffado server"
        }
    }

    /// Where to get a key, shown under the key field.
    var keyHelp: String? {
        switch self {
        case .ollamaCloud: return "Create a key at ollama.com/settings/keys."
        case .openRouter: return "Create a key at openrouter.ai/keys — or sign in below instead."
        case .anthropic: return "Create a key in the Claude Console (platform.claude.com)."
        case .openAICompatible: return "Use the key from your provider's dashboard."
        default: return nil
        }
    }
}

extension ProviderConfig {
    /// e.g. "On-device · Qwen3 1.7B", "Ollama Cloud · gemma4:31b"
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
