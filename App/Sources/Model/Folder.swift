import Foundation
import SwiftData
import RiffCore

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    /// Deleting a folder leaves its recordings in place, unfiled.
    @Relationship(deleteRule: .nullify, inverse: \RecordingItem.folder)
    var recordings: [RecordingItem] = []

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.createdAt = .now
    }
}

/// Which notes a Library chat (or the recordings list) covers.
enum NoteScope: Hashable {
    case all
    case unfiled
    case folder(UUID)

    var tag: String {
        switch self {
        case .all: return "all"
        case .unfiled: return "unfiled"
        case .folder(let id): return id.uuidString
        }
    }

    init(tag: String) {
        switch tag {
        case "all": self = .all
        case "unfiled": self = .unfiled
        default: self = UUID(uuidString: tag).map(NoteScope.folder) ?? .all
        }
    }

    func includes(_ r: RecordingItem) -> Bool {
        switch self {
        case .all: return true
        case .unfiled: return r.folder == nil
        case .folder(let id): return r.folder?.id == id
        }
    }

    func title(folders: [Folder]) -> String {
        switch self {
        case .all: return "All notes"
        case .unfiled: return "Unfiled"
        case .folder(let id): return folders.first { $0.id == id }?.name ?? "Folder"
        }
    }
}

extension RecordingItem {
    var noteSource: NoteSource {
        NoteSource(id: id.uuidString, title: title, date: createdAt, transcript: transcript, summary: summary)
    }
}
