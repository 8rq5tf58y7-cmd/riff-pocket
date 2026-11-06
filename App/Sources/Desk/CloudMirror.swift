import Foundation
import SwiftData
import RiffCore

/// Keeps the Claude connector (Cloudflare Worker) up to date: a one-way mirror of your notes
/// — titles, summaries, transcripts, folders and attachment text — so Claude on claude.ai and the
/// Claude iPhone app can search and read them. Audio never leaves the phone.
@MainActor
final class CloudMirror: ObservableObject {
    static let shared = CloudMirror()
    private static let keyKey = "cloud.syncKey"

    @Published private(set) var isPushing = false
    @Published private(set) var lastPush: Date?
    @Published private(set) var info: DeskInfo?
    @Published var lastError: String?

    var syncKey: String? { Keychain.string(Self.keyKey) }
    var isConfigured: Bool {
        let s = SettingsStore.shared.settings
        return s.cloudEnabled && !s.cloudURL.isEmpty && syncKey != nil
    }
    var connectorURL: String { SettingsStore.shared.settings.cloudURL + "/mcp" }

    private var client: DeskClient? {
        guard isConfigured, let key = syncKey else { return nil }
        return DeskClient(baseURL: SettingsStore.shared.settings.cloudURL, token: key)
    }

    /// Verifies the URL + sync key before saving them.
    func configure(url raw: String, key: String) async throws {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix("/mcp") { url = String(url.dropLast(4)) }
        guard url.hasPrefix("https://") else { throw MirrorError.needsHTTPS }
        let probe = DeskClient(baseURL: url, token: key.trimmingCharacters(in: .whitespaces))
        info = try await probe.info()
        Keychain.setString(key.trimmingCharacters(in: .whitespaces), for: Self.keyKey)
        SettingsStore.shared.settings.cloudURL = url
        SettingsStore.shared.settings.cloudEnabled = true
    }

    func disconnect(context: ModelContext) {
        Keychain.delete(Self.keyKey)
        SettingsStore.shared.settings.cloudEnabled = false
        info = nil
        for item in (try? context.fetch(FetchDescriptor<RecordingItem>())) ?? [] { item.cloudPushedHash = nil }
        try? context.save()
    }

    func sharePlaud(_ creds: PlaudCredentials) async throws {
        guard let client else { throw MirrorError.notConfigured }
        try await client.connectPlaud(creds)
        info = try? await client.info()
    }

    /// Pushes changed notes and folders, then removes notes deleted on the phone. Cheap when nothing changed.
    @discardableResult
    func push(context: ModelContext) async -> Int {
        guard let client, !isPushing else { return 0 }
        isPushing = true
        lastError = nil
        defer { isPushing = false }
        var pushed = 0
        do {
            for f in try context.fetch(FetchDescriptor<Folder>()) {
                try await client.putFolder(DeskFolder(id: f.id.uuidString, name: f.name, updatedAt: f.createdAt))
            }
            let items = try context.fetch(FetchDescriptor<RecordingItem>())
            for item in items {
                let dto = item.deskDTO
                let print = DeskClient.fingerprint(dto)
                guard print != item.cloudPushedHash else { continue }
                try await client.putNote(dto)
                item.cloudPushedHash = print
                pushed += 1
                if pushed % 20 == 0 { try? context.save() }
            }
            try await client.prune(keep: items.map { $0.id.uuidString })
            try context.save()
            info = try? await client.info()
            lastPush = .now
        } catch {
            lastError = errorMessage(error)
        }
        return pushed
    }
}

enum MirrorError: LocalizedError {
    case needsHTTPS, notConfigured
    var errorDescription: String? {
        switch self {
        case .needsHTTPS: return "Use the https:// address of your deployed connector (e.g. https://riff-pocket-connector.<you>.workers.dev)."
        case .notConfigured: return "Set up the Claude connector first."
        }
    }
}
