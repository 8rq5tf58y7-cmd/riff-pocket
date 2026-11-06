import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Sync contract between the iPhone app and the Riff Desk desktop companion.
// Dates travel as seconds since 1970 (Double) so Swift and Python agree exactly.

public struct DeskAttachment: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var contentType: String
    public var size: Int
    public var text: String?
    public var deleted: Bool

    public init(id: String, name: String, contentType: String, size: Int, text: String?, deleted: Bool = false) {
        self.id = id
        self.name = name
        self.contentType = contentType
        self.size = size
        self.text = text
        self.deleted = deleted
    }
}

public struct DeskNote: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// The user renamed it by hand; automatic titles must not overwrite it.
    public var titleLocked: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var duration: Double
    public var source: String
    public var plaudId: String?
    public var folderId: String?
    public var transcript: Transcript?
    public var transcriptSource: String?
    public var summary: String?
    public var summarySource: String?
    public var summaryStyle: SummaryStyle?
    /// The rendered prompt for this note's style, so the desktop doesn't need its own copy of the rules.
    public var summaryInstructions: String?
    public var audioName: String?
    public var hasAudio: Bool
    public var attachments: [DeskAttachment]
    public var deleted: Bool

    public init(id: String, title: String, titleLocked: Bool = false, createdAt: Date, updatedAt: Date,
                duration: Double, source: String, plaudId: String? = nil, folderId: String? = nil,
                transcript: Transcript? = nil, transcriptSource: String? = nil, summary: String? = nil,
                summarySource: String? = nil, summaryStyle: SummaryStyle? = nil, summaryInstructions: String? = nil,
                audioName: String? = nil, hasAudio: Bool = false, attachments: [DeskAttachment] = [], deleted: Bool = false) {
        self.id = id
        self.title = title
        self.titleLocked = titleLocked
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.source = source
        self.plaudId = plaudId
        self.folderId = folderId
        self.transcript = transcript
        self.transcriptSource = transcriptSource
        self.summary = summary
        self.summarySource = summarySource
        self.summaryStyle = summaryStyle
        self.summaryInstructions = summaryInstructions
        self.audioName = audioName
        self.hasAudio = hasAudio
        self.attachments = attachments
        self.deleted = deleted
    }

    /// Equality ignoring `updatedAt` and transport-only fields: "did the content change?"
    public func sameContent(as other: DeskNote) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast; b.updatedAt = .distantPast
        a.hasAudio = false; b.hasAudio = false
        a.summaryInstructions = nil; b.summaryInstructions = nil
        a.attachments.sort { $0.id < $1.id }; b.attachments.sort { $0.id < $1.id }
        return a == b
    }
}

public struct DeskFolder: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var updatedAt: Date
    public var deleted: Bool

    public init(id: String, name: String, updatedAt: Date, deleted: Bool = false) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.deleted = deleted
    }
}

public struct DeskChanges: Codable, Sendable {
    public var cursor: Int
    public var notes: [DeskNote]
    public var folders: [DeskFolder]
}

public struct DeskInfo: Codable, Sendable {
    public var name: String
    public var version: String
    public var processing: Bool
    public var plaudConnected: Bool
}

public struct DeskSettings: Codable, Sendable {
    public var defaultSummaryInstructions: String
    public var titleInstructions: String
    public var autoTranscribe: Bool
    public var autoSummarize: Bool
    public var autoTitle: Bool

    public init(defaultSummaryInstructions: String, titleInstructions: String = NoteTitle.instructions,
                autoTranscribe: Bool, autoSummarize: Bool, autoTitle: Bool) {
        self.defaultSummaryInstructions = defaultSummaryInstructions
        self.titleInstructions = titleInstructions
        self.autoTranscribe = autoTranscribe
        self.autoSummarize = autoSummarize
        self.autoTitle = autoTitle
    }
}

// MARK: - Merge

/// Three-way merge per field: whichever side changed a field since the last sync wins;
/// if both changed it, the phone's value wins (except that a real title beats a placeholder).
public enum DeskMerge {
    static func pick<T: Equatable>(_ base: T, _ local: T, _ remote: T) -> T {
        if local == remote { return local }
        if local == base { return remote }
        return local
    }

    public static func merge(base: DeskNote?, local: DeskNote, remote: DeskNote) -> DeskNote {
        let b = base ?? DeskNote(id: local.id, title: "", createdAt: local.createdAt, updatedAt: .distantPast,
                                 duration: 0, source: local.source)
        var m = local
        m.title = pick(b.title, local.title, remote.title)
        if local.title != remote.title, local.title != b.title, remote.title != b.title,
           NoteTitle.isPlaceholder(local.title), !NoteTitle.isPlaceholder(remote.title) {
            m.title = remote.title
        }
        m.titleLocked = local.titleLocked || remote.titleLocked
        m.duration = local.duration > 0 ? local.duration : remote.duration
        m.plaudId = local.plaudId ?? remote.plaudId
        m.folderId = pick(b.folderId, local.folderId, remote.folderId)
        // Transcript and summary travel with their source label.
        if pick(b.transcript, local.transcript, remote.transcript) == remote.transcript, local.transcript != remote.transcript {
            m.transcript = remote.transcript
            m.transcriptSource = remote.transcriptSource
        }
        if pick(b.summary, local.summary, remote.summary) == remote.summary, local.summary != remote.summary {
            m.summary = remote.summary
            m.summarySource = remote.summarySource
        }
        m.summaryStyle = pick(b.summaryStyle, local.summaryStyle, remote.summaryStyle)
        m.summaryInstructions = local.summaryInstructions ?? remote.summaryInstructions
        m.audioName = local.audioName ?? remote.audioName
        m.hasAudio = local.hasAudio || remote.hasAudio
        var byId: [String: DeskAttachment] = [:]
        for a in remote.attachments { byId[a.id] = a }
        for a in local.attachments {
            if let r = byId[a.id] {
                var merged = a
                merged.deleted = a.deleted || r.deleted
                merged.text = a.text ?? r.text
                byId[a.id] = merged
            } else {
                byId[a.id] = a
            }
        }
        m.attachments = byId.values.sorted { $0.id < $1.id }
        m.deleted = local.deleted || remote.deleted
        m.updatedAt = max(local.updatedAt, remote.updatedAt)
        return m
    }
}

// MARK: - Stable ids

public enum NoteID {
    /// The same Plaud recording gets the same note id on the phone and the desktop,
    /// so syncing from both never creates duplicates. FNV-1a based; mirrored in riffdesk/ids.py.
    public static func forPlaud(_ plaudId: String) -> String {
        let bytes = Array("plaud:\(plaudId)".utf8)
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 }
            return h
        }
        let h1 = fnv(0xcbf29ce484222325), h2 = fnv(0x84222325cbf29ce4)
        var out = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            out[i] = UInt8((h1 >> (56 - 8 * UInt64(i))) & 0xff)
            out[8 + i] = UInt8((h2 >> (56 - 8 * UInt64(i))) & 0xff)
        }
        out[6] = (out[6] & 0x0f) | 0x50 // version 5-style
        out[8] = (out[8] & 0x3f) | 0x80 // RFC 4122 variant
        let hex = out.map { String(format: "%02X", $0) }.joined()
        let p = Array(hex)
        return "\(String(p[0..<8]))-\(String(p[8..<12]))-\(String(p[12..<16]))-\(String(p[16..<20]))-\(String(p[20..<32]))"
    }
}

// MARK: - Pairing

public enum DeskPairing {
    /// Parses `riffpocket://pair?url=http://192.168.1.20:8765&token=…` (what the desktop's QR code holds).
    public static func parse(_ link: String) -> (baseURL: String, token: String)? {
        guard let comps = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == "riffpocket", comps.host == "pair",
              let url = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              url.hasPrefix("http://") || url.hasPrefix("https://"), token.count >= 16 else { return nil }
        return (url.trimmingTrailingSlashes(), token)
    }
}

// MARK: - Client

public struct DeskClient: Sendable {
    public var baseURL: String
    public var token: String
    private let http: HTTPClient

    public init(baseURL: String, token: String, http: HTTPClient = HTTPClient()) {
        self.baseURL = baseURL.trimmingTrailingSlashes()
        self.token = token
        self.http = http
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval = 30) throws -> URLRequest {
        var req = URLRequest(url: try makeURL(baseURL, path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func pct(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    public func info() async throws -> DeskInfo {
        try await http.sendJSON(try request("api/v1/info", timeout: 8), as: DeskInfo.self)
    }

    public func changes(since cursor: Int) async throws -> DeskChanges {
        try await http.sendJSON(try request("api/v1/changes?since=\(cursor)"), as: DeskChanges.self, decoder: Self.decoder())
    }

    @discardableResult
    public func putNote(_ note: DeskNote) async throws -> DeskNote {
        var req = try request("api/v1/notes/\(pct(note.id))", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder().encode(note)
        return try await http.sendJSON(req, as: DeskNote.self, decoder: Self.decoder())
    }

    public func putFolder(_ folder: DeskFolder) async throws {
        var req = try request("api/v1/folders/\(pct(folder.id))", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder().encode(folder)
        _ = try await http.send(req)
    }

    public func putSettings(_ settings: DeskSettings) async throws {
        var req = try request("api/v1/settings", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(settings)
        _ = try await http.send(req)
    }

    public func putAudio(noteId: String, fileURL: URL) async throws {
        var req = try request("api/v1/notes/\(pct(noteId))/audio?name=\(pct(fileURL.lastPathComponent))", method: "PUT", timeout: 600)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Data(contentsOf: fileURL)
        _ = try await http.send(req)
    }

    public func getAudio(noteId: String) async throws -> Data {
        try await http.send(try request("api/v1/notes/\(pct(noteId))/audio", timeout: 600))
    }

    public func putAttachment(noteId: String, attachment: DeskAttachment, fileURL: URL) async throws {
        let path = "api/v1/notes/\(pct(noteId))/attachments/\(pct(attachment.id))?name=\(pct(attachment.name))&type=\(pct(attachment.contentType))"
        var req = try request(path, method: "PUT", timeout: 300)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Data(contentsOf: fileURL)
        _ = try await http.send(req)
    }

    public func getAttachment(noteId: String, attachmentId: String) async throws -> Data {
        try await http.send(try request("api/v1/notes/\(pct(noteId))/attachments/\(pct(attachmentId))", timeout: 300))
    }

    /// Mirror targets (the Claude connector): remove notes that no longer exist on the phone.
    @discardableResult
    public func prune(keep ids: [String]) async throws -> Int {
        var req = try request("api/v1/notes/prune", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["keep": ids])
        struct Pruned: Decodable { let removed: Int }
        return try await http.sendJSON(req, as: Pruned.self).removed
    }

    /// Stable fingerprint of a note's content (ignores timestamps/transport flags), to push only changes.
    public static func fingerprint(_ note: DeskNote) -> String {
        var n = note
        n.updatedAt = Date(timeIntervalSince1970: 0)
        n.hasAudio = false
        n.attachments.sort { $0.id < $1.id }
        let e = encoder()
        e.outputFormatting = [.sortedKeys]
        let data = (try? e.encode(n)) ?? Data()
        // FNV-1a 64 is plenty to detect changes (not a security boundary).
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16) + "-\(data.count)"
    }

    /// Lets the desktop sync Plaud itself (so new recordings are processed while the phone sleeps).
    public func connectPlaud(_ credentials: PlaudCredentials) async throws {
        var req = try request("api/v1/plaud/connect", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(credentials)
        _ = try await http.send(req)
    }
}
