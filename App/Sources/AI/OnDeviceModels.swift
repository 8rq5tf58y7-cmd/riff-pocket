import Foundation
import FoundationModels
import WhisperKit
import RiffCore

// MARK: - Apple Foundation Models (built into iOS 26, ~3B, free, private)

struct AppleFoundationChatModel: ChatModel {
    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let why):
                return "Apple's on-device model isn't available (\(why)). Turn on Apple Intelligence in Settings, or pick another provider."
            }
        }
    }

    var displayName: String { "Apple on-device" }
    /// ~4k-token context window shared with the answer; the Summarizer chunks to this.
    var contextCharacterBudget: Int { 6_000 }

    func complete(_ messages: [ChatMessage], options: ChatOptions) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw Failure.unavailable(String(describing: model.availability))
        }
        let instructions = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let prompt = messages.filter { $0.role != .system }.map { m in
            m.role == .assistant ? "Assistant: \(m.content)" : m.content
        }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt)
        return response.content
    }
}

// MARK: - WhisperKit (Whisper on the Neural Engine)

actor WhisperKitCache {
    static let shared = WhisperKitCache()
    private var pipes: [String: WhisperKit] = [:]

    func pipe(model: String) async throws -> WhisperKit {
        if let p = pipes[model] { return p }
        // Downloads the CoreML model on first use (base ≈ 150 MB, small ≈ 500 MB).
        let p = try await WhisperKit(WhisperKitConfig(model: model))
        pipes[model] = p
        return p
    }
}

struct WhisperKitTranscriber: Transcriber {
    let model: String
    var displayName: String { "WhisperKit (\(model))" }

    func transcribe(fileURL: URL, language: String?) async throws -> Transcript {
        let pipe = try await WhisperKitCache.shared.pipe(model: model)
        var options = DecodingOptions()
        options.language = language
        options.skipSpecialTokens = true
        let results = try await pipe.transcribe(audioPath: fileURL.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).map {
            TranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
        return Transcript(language: results.first?.language, segments: segments)
    }
}
