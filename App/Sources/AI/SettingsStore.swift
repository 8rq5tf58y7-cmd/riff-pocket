import Foundation
import RiffCore

enum AITask: String, CaseIterable, Identifiable {
    case transcribe, summarize, chat
    var id: String { rawValue }

    var label: String {
        switch self {
        case .transcribe: return "Transcription"
        case .summarize: return "Summaries"
        case .chat: return "Ask (chat)"
        }
    }

    /// Keychain account for this task's API key (OpenRouter uses one shared key).
    var keychainKey: String { "apikey.\(rawValue)" }
}

struct AppSettings: Codable, Equatable {
    var transcribe = ProviderConfig.preset(.whisperKit, forTranscription: true)
    var summarize = ProviderConfig.preset(.appleOnDevice)
    var chat = ProviderConfig.preset(.appleOnDevice)
    /// Prefer Plaud's own transcript/summary when it exists.
    var preferPlaudContent = true
    var language = "" // empty = auto-detect
    var riffadoURL = ""

    func config(for task: AITask) -> ProviderConfig {
        switch task {
        case .transcribe: return transcribe
        case .summarize: return summarize
        case .chat: return chat
        }
    }

    mutating func setConfig(_ c: ProviderConfig, for task: AITask) {
        switch task {
        case .transcribe: transcribe = c
        case .summarize: summarize = c
        case .chat: chat = c
        }
    }
}

final class SettingsStore: ObservableObject {
    private static let key = "riffpocket.settings.v1"

    @Published var settings: AppSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Self.key)
            }
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
    }
}
