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

    /// Per-task key account used by earlier builds (read as a fallback only).
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

    // Summary templates
    var customStyles: [SummaryStyle] = []
    var defaultStyleId = SummaryStyle.meeting.id

    // Background
    var backgroundSync = true
    var autoTranscribe = false
    var autoSummarize = false
    var processOnlyWhileCharging = true
    var notifications = true

    init() {}

    /// Tolerant decoding so settings saved by older builds keep working when fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        transcribe = (try? c.decode(ProviderConfig.self, forKey: .transcribe)) ?? d.transcribe
        summarize = (try? c.decode(ProviderConfig.self, forKey: .summarize)) ?? d.summarize
        chat = (try? c.decode(ProviderConfig.self, forKey: .chat)) ?? d.chat
        preferPlaudContent = (try? c.decode(Bool.self, forKey: .preferPlaudContent)) ?? d.preferPlaudContent
        language = (try? c.decode(String.self, forKey: .language)) ?? d.language
        riffadoURL = (try? c.decode(String.self, forKey: .riffadoURL)) ?? d.riffadoURL
        customStyles = (try? c.decode([SummaryStyle].self, forKey: .customStyles)) ?? d.customStyles
        defaultStyleId = (try? c.decode(String.self, forKey: .defaultStyleId)) ?? d.defaultStyleId
        backgroundSync = (try? c.decode(Bool.self, forKey: .backgroundSync)) ?? d.backgroundSync
        autoTranscribe = (try? c.decode(Bool.self, forKey: .autoTranscribe)) ?? d.autoTranscribe
        autoSummarize = (try? c.decode(Bool.self, forKey: .autoSummarize)) ?? d.autoSummarize
        processOnlyWhileCharging = (try? c.decode(Bool.self, forKey: .processOnlyWhileCharging)) ?? d.processOnlyWhileCharging
        notifications = (try? c.decode(Bool.self, forKey: .notifications)) ?? d.notifications
        // Transcription via Ollama was never possible (no speech-to-text endpoint).
        if !transcribe.kind.canTranscribe { transcribe = d.transcribe }
    }

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

    var allStyles: [SummaryStyle] { SummaryStyle.builtIn + customStyles }

    func style(id: String) -> SummaryStyle? { allStyles.first { $0.id == id } }

    var defaultStyle: SummaryStyle { style(id: defaultStyleId) ?? .meeting }

    /// Adds or replaces a custom template.
    mutating func saveStyle(_ s: SummaryStyle) {
        guard !s.isBuiltIn else { return }
        if let i = customStyles.firstIndex(where: { $0.id == s.id }) { customStyles[i] = s } else { customStyles.append(s) }
    }

    mutating func deleteStyle(id: String) {
        customStyles.removeAll { $0.id == id }
        if defaultStyleId == id { defaultStyleId = SummaryStyle.meeting.id }
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
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
