import Foundation
import SwiftData
import RiffCore

/// Two-way sync with the Riff Desk desktop companion.
///
/// Pull: changes since our cursor → 3-way merge into local notes (the desk may have transcribed,
/// summarized or renamed them while the phone slept). Push: anything changed locally since the last
/// agreed state, plus audio and attachment files the desk doesn't have yet.
@MainActor
final class DeskSync: ObservableObject {
    static let shared = DeskSync()
    private static let tokenKey = "desk.token"
    private static let cursorKey = "desk.cursor"

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published var lastError: String?
    @Published private(set) var info: DeskInfo?

    var token: String? { Keychain.string(Self.tokenKey) }
    var isPaired: Bool { SettingsStore.shared.settings.deskEnabled && !SettingsStore.shared.settings.deskURL.isEmpty && token != nil }

    private var client: DeskClient? {
        guard isPaired, let token else { return nil }
        return DeskClient(baseURL: SettingsStore.shared.settings.deskURL, token: token)
    }

    // MARK: Pairing

    /// Accepts the QR/pairing link from the desktop; verifies it before saving.
    func pair(link: String) async throws -> DeskInfo {
        guard let p = DeskPairing.parse(link) else {
            throw DeskError.badLink
        }
        let info = try await DeskClient(baseURL: p.baseURL, token: p.token).info()
        Keychain.setString(p.token, for: Self.tokenKey)
        SettingsStore.shared.settings.deskURL = p.baseURL
        SettingsStore.shared.settings.deskEnabled = true
        UserDefaults.standard.set(0, forKey: Self.cursorKey)
        self.info = info
        try? await pushSettings()
        return info
    }

    func unpair() {
        Keychain.delete(Self.tokenKey)
        SettingsStore.shared.settings.deskEnabled = false
        UserDefaults.standard.removeObject(forKey: Self.cursorKey)
        info = nil
    }

    /// Lets the desktop pull Plaud itself, so recordings are processed while the phone is asleep.
    func shareAccount(_ creds: PlaudCredentials) async throws {
        guard let client else { throw DeskError.notPaired }
        try await client.connectPlaud(creds)
        info = try? await client.info()
    }

    /// Default summary format, title rules and automation flags follow the phone.
    func pushSettings() async throws {
        guard let client else { return }
        let s = SettingsStore.shared.settings
        try await client.putSettings(DeskSettings(
            defaultSummaryInstructions: s.defaultStyle.instructions,
            autoTranscribe: s.autoTranscribe, autoSummarize: s.autoSummarize, autoTitle: s.autoTitle))
    }

    // MARK: Sync

    /// Returns how many notes changed on the phone because of the desktop.
    @discardableResult
    func sync(context: ModelContext) async -> Int {
        guard let client, !isSyncing else { return 0 }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }
        var changedHere = 0
        do {
            info = try await client.info()
            migratePlaudIds(context: context)
            let folders = try context.fetch(FetchDescriptor<Folder>())
            let notes = try context.fetch(FetchDescriptor<RecordingItem>())
            var byId = Dictionary(notes.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })

            // 1. Pull
            let cursor = UserDefaults.standard.integer(forKey: Self.cursorKey)
            let changes = try await client.changes(since: cursor)
            var folderById = Dictionary(folders.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            for f in changes.folders {
                if f.deleted {
                    if let local = folderById[f.id] { context.delete(local); folderById[f.id] = nil }
                } else if let local = folderById[f.id] {
                    if local.name != f.name { local.name = f.name }
                } else if let uuid = UUID(uuidString: f.id) {
                    let nf = Folder(name: f.name)
                    nf.id = uuid
                    context.insert(nf)
                    folderById[f.id] = nf
                }
            }
            for remote in changes.notes {
                if let local = byId[remote.id] {
                    let base = local.deskSnapshot
                    let mine = local.deskDTO
                    if remote.deleted && (base.map { mine.sameContent(as: $0) } ?? true) {
                        try? FileManager.default.removeItem(at: local.audioURL)
                        context.delete(local)
                        byId[remote.id] = nil
                        continue
                    }
                    let merged = DeskMerge.merge(base: base, local: mine, remote: remote)
                    if !merged.sameContent(as: mine) {
                        local.apply(merged, folders: folderById)
                        changedHere += 1
                    }
                    // Agreed state = what the desk has; if we still differ, the push below sends it.
                    local.deskSnapshot = remote
                    local.deskUpdatedAt = remote.updatedAt
                } else if !remote.deleted, let uuid = UUID(uuidString: remote.id) {
                    let item = RecordingItem(title: remote.title, createdAt: remote.createdAt, duration: remote.duration,
                                             audioFileName: "", source: remote.source, id: uuid)
                    context.insert(item)
                    item.apply(remote, folders: folderById)
                    item.deskSnapshot = remote
                    item.deskUpdatedAt = remote.updatedAt
                    byId[remote.id] = item
                    changedHere += 1
                }
            }
            try context.save()

            // 2. Fetch files we're missing (audio for desk-imported or desk-synced Plaud notes).
            for remote in changes.notes where remote.hasAudio && !remote.deleted {
                guard let item = byId[remote.id], !item.hasAudioFile else { continue }
                let data = try await client.getAudio(noteId: remote.id)
                let ext = remote.audioName.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
                let dest = RecordingStorage.newFileURL(ext: ext.isEmpty ? "m4a" : ext)
                try data.write(to: dest)
                item.audioFileName = dest.lastPathComponent
                try? context.save()
            }

            // 3. Push folders and changed notes (+ files the desk lacks).
            for f in try context.fetch(FetchDescriptor<Folder>()) {
                try await client.putFolder(DeskFolder(id: f.id.uuidString, name: f.name, updatedAt: f.createdAt))
            }
            for item in byId.values {
                var dto = item.deskDTO
                let snapshot = item.deskSnapshot
                let needsMeta = snapshot.map { !dto.sameContent(as: $0) } ?? true
                let needsAudio = item.hasAudioFile && !(snapshot?.hasAudio ?? false)
                let knownAtts = Set((snapshot?.attachments ?? []).map(\.id))
                let newAtts = item.attachments.filter { !knownAtts.contains($0.id) }
                guard needsMeta || needsAudio || !newAtts.isEmpty else { continue }
                if needsMeta { dto.updatedAt = .now }
                var stored = try await client.putNote(dto)
                if needsAudio {
                    try await client.putAudio(noteId: dto.id, fileURL: item.audioURL)
                    stored.hasAudio = true
                }
                for att in newAtts where att.hasLocalFile {
                    try await client.putAttachment(noteId: dto.id, attachment: att.deskDTO, fileURL: att.fileURL)
                }
                item.deskSnapshot = stored
                item.deskUpdatedAt = stored.updatedAt
            }
            try context.save()
            // Our own pushes advanced the desk's cursor; skip re-reading them next time.
            UserDefaults.standard.set(try await client.changes(since: changes.cursor).cursor, forKey: Self.cursorKey)
            lastSync = .now
        } catch {
            lastError = errorMessage(error)
        }
        return changedHere
    }

    /// Plaud notes get the same id on phone and desktop (NoteID.forPlaud), so both can import
    /// the same recording without duplicates. Older notes are moved to that id once.
    private func migratePlaudIds(context: ModelContext) {
        guard let items = try? context.fetch(FetchDescriptor<RecordingItem>()) else { return }
        var taken = Set(items.map(\.id))
        for item in items {
            guard let pid = item.plaudId, item.deskSnapshotData == nil,
                  let stable = UUID(uuidString: NoteID.forPlaud(pid)), item.id != stable, !taken.contains(stable) else { continue }
            taken.remove(item.id)
            item.id = stable
            taken.insert(stable)
        }
        try? context.save()
    }
}

enum DeskError: LocalizedError {
    case badLink, notPaired
    var errorDescription: String? {
        switch self {
        case .badLink: return "That isn't a Riff Desk pairing link. Open Settings & pairing in Riff Desk and scan its code."
        case .notPaired: return "Pair with Riff Desk first."
        }
    }
}

// MARK: - Mapping

extension RecordingItem {
    var deskSnapshot: DeskNote? {
        get { deskSnapshotData.flatMap { try? DeskClient.decoder().decode(DeskNote.self, from: $0) } }
        set { deskSnapshotData = newValue.flatMap { try? DeskClient.encoder().encode($0) } }
    }

    var deskDTO: DeskNote {
        DeskNote(
            id: id.uuidString, title: title, titleLocked: titleLocked, createdAt: createdAt,
            updatedAt: deskUpdatedAt ?? createdAt, duration: duration, source: source, plaudId: plaudId,
            folderId: folder?.id.uuidString, transcript: transcript, transcriptSource: transcriptSource,
            summary: summary, summarySource: summarySource, summaryStyle: summaryStyle,
            summaryInstructions: (summaryStyle ?? SettingsStore.shared.settings.defaultStyle).instructions,
            audioName: audioFileName.isEmpty ? nil : audioFileName, hasAudio: hasAudioFile,
            attachments: attachments.map(\.deskDTO).sorted { $0.id < $1.id }, deleted: false
        )
    }

    func apply(_ n: DeskNote, folders: [String: Folder]) {
        title = n.title
        titleLocked = n.titleLocked
        if duration <= 0 { duration = n.duration }
        plaudId = plaudId ?? n.plaudId
        folder = n.folderId.flatMap { folders[$0] }
        if n.transcript != transcript { transcript = n.transcript; transcriptSource = n.transcriptSource }
        if n.summary != summary { summary = n.summary; summarySource = n.summarySource }
        if n.summaryStyle != nil { summaryStyle = n.summaryStyle }
        // Attachments added on the desktop arrive as text (Ask/Library chat) with their file fetched on demand.
        let known = Set(attachments.map(\.id))
        for a in n.attachments where !a.deleted && !known.contains(a.id) {
            let att = NoteAttachment(id: a.id, name: a.name, contentType: a.contentType, size: a.size, fileName: "")
            att.extractedText = a.text
            modelContext?.insert(att)  // insert first, then link
            att.note = self
        }
        for att in attachments where n.attachments.contains(where: { $0.id == att.id && $0.deleted }) {
            if att.hasLocalFile { try? FileManager.default.removeItem(at: att.fileURL) }
            modelContext?.delete(att)
        }
    }
}

extension NoteAttachment {
    var deskDTO: DeskAttachment {
        DeskAttachment(id: id, name: name, contentType: contentType, size: size, text: extractedText)
    }
}
