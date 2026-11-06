import Foundation
import SwiftData
import AVFoundation
import RiffCore

@Model
final class RecordingItem {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var duration: Double
    /// File name inside `RecordingStorage.directory`.
    var audioFileName: String
    /// "plaud", "mic", "import"
    var source: String
    /// Plaud file id when synced from the Plaud cloud.
    var plaudId: String?
    /// Plaud `version_ms` at last sync (detects renames / new transcripts on Plaud's side).
    var plaudVersion: Double = 0
    /// Deleted or trashed on Plaud; kept on the phone.
    var goneRemotely: Bool = false
    var transcriptData: Data?
    /// "plaud" or the provider that produced it.
    var transcriptSource: String?
    var summary: String?
    var summarySource: String?
    var folder: Folder?
    /// This note's summary style (format, length, sections…). nil = the default template.
    var summaryStyleData: Data?
    /// Set by background processing so it doesn't retry a failing note forever.
    var autoProcessFailures: Int = 0
    /// The user named it; automatic (AI) titles leave it alone.
    var titleLocked: Bool = false
    /// Files attached to this note (deleted with it).
    @Relationship(deleteRule: .cascade, inverse: \NoteAttachment.note)
    var attachments: [NoteAttachment] = []
    /// Last state agreed with the desktop companion (base for 3-way merges). nil = never synced.
    var deskSnapshotData: Data?
    var deskUpdatedAt: Date?
    /// Fingerprint of what the Claude connector last received (push only changes).
    var cloudPushedHash: String?

    init(title: String, createdAt: Date = .now, duration: Double, audioFileName: String, source: String,
         id: UUID = UUID()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.source = source
    }

    var audioURL: URL { RecordingStorage.directory.appendingPathComponent(audioFileName) }

    var hasAudioFile: Bool { !audioFileName.isEmpty && FileManager.default.fileExists(atPath: audioURL.path) }

    /// Text of attached files, for Ask / Library chat.
    var documents: [NoteDocument] { attachments.sorted { $0.addedAt < $1.addedAt }.compactMap(\.document) }

    var summaryStyle: SummaryStyle? {
        get { summaryStyleData.flatMap { try? JSONDecoder().decode(SummaryStyle.self, from: $0) } }
        set { summaryStyleData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var transcript: Transcript? {
        get { transcriptData.flatMap { try? JSONDecoder().decode(Transcript.self, from: $0) } }
        set { transcriptData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

enum RecordingStorage {
    /// Documents/Recordings — visible in the Files app.
    static var directory: URL {
        let dir = URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newFileURL(ext: String) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    static func importFile(from url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = newFileURL(ext: url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func duration(of url: URL) async -> Double {
        guard let d = try? await AVURLAsset(url: url).load(.duration) else { return 0 }
        return d.seconds.isFinite ? d.seconds : 0
    }
}
