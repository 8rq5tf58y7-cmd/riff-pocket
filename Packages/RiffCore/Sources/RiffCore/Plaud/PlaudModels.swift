// Swift port of Riffado's Plaud types (src/types/plaud.ts, AGPL-3.0).
// Everything optional/lenient: this is an unofficial API and shapes drift.
import Foundation

public enum PlaudRegion: String, CaseIterable, Codable, Sendable, Identifiable {
    case global, eu, apac, china

    public var id: String { rawValue }

    public var apiBase: String {
        switch self {
        case .global: return "https://api.plaud.ai"
        case .eu: return "https://api-euc1.plaud.ai"
        case .apac: return "https://api-apse1.plaud.ai"
        case .china: return "https://api.plaud.cn"
        }
    }

    public var label: String {
        switch self {
        case .global: return "Global (api.plaud.ai)"
        case .eu: return "EU – Frankfurt (api-euc1)"
        case .apac: return "Asia Pacific – Singapore (api-apse1)"
        case .china: return "China mainland (api.plaud.cn)"
        }
    }

    public static func from(apiBase: String) -> PlaudRegion? {
        allCases.first { $0.apiBase == apiBase.trimmingCharacters(in: .whitespaces).trimmingTrailingSlashes() }
    }

    /// SSRF-style guard from Riffado: only https plaud.ai / plaud.cn hosts.
    public static func isValidAPIBase(_ s: String) -> Bool {
        guard let url = URL(string: s), url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "plaud.ai" || host.hasSuffix(".plaud.ai") || host == "plaud.cn" || host.hasSuffix(".plaud.cn")
    }
}

/// What gets stored in the Keychain after connecting.
public struct PlaudCredentials: Codable, Hashable, Sendable {
    public var userToken: String
    public var apiBase: String
    public var workspaceId: String?
    public var email: String?

    public init(userToken: String, apiBase: String, workspaceId: String? = nil, email: String? = nil) {
        self.userToken = userToken
        self.apiBase = apiBase
        self.workspaceId = workspaceId
        self.email = email
    }

    public var expiresAt: Date? { PlaudJWT.expiry(userToken) }
}

public struct PlaudDevice: Codable, Hashable, Sendable {
    public var sn: String?
    public var name: String?
    public var model: String?
    public var version_number: Double?
}

struct PlaudDeviceListResponse: Decodable {
    var status: Int?
    var msg: String?
    var data_devices: [PlaudDevice]?
}

public struct PlaudRecording: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var filename: String?
    public var filesize: Double?
    public var filetype: String?
    public var version_ms: Double?
    public var edit_time: Double?
    public var is_trash: Bool?
    /// Unix ms
    public var start_time: Double?
    public var end_time: Double?
    /// ms
    public var duration: Double?
    public var serial_number: String?
    public var is_trans: Bool?
    public var is_summary: Bool?
    /// "v4" when listed through Plaud 4.0's `/file-app/v4` API (flags need `hydrate`).
    public var source: String?

    public init(id: String, filename: String? = nil, version_ms: Double? = nil, start_time: Double? = nil,
                duration: Double? = nil, is_trans: Bool? = nil, is_summary: Bool? = nil) {
        self.id = id
        self.filename = filename
        self.version_ms = version_ms
        self.start_time = start_time
        self.duration = duration
        self.is_trans = is_trans
        self.is_summary = is_summary
    }

    public var startedAt: Date? { start_time.map { Date(timeIntervalSince1970: $0 / 1000) } }
    public var durationSeconds: Double { (duration ?? 0) / 1000 }
    /// Change marker used by sync to detect edits on Plaud's side.
    public var versionMarker: Double { version_ms ?? edit_time ?? 0 }
}

struct PlaudRecordingsResponse: Decodable {
    var status: Int?
    var msg: String?
    var data_file_total: Int?
    var data_file_list: [PlaudRecording]?
}

struct PlaudTempURLResponse: Decodable {
    var status: Int?
    var msg: String?
    var temp_url: String?
    var temp_url_opus: String?
}

struct PlaudStatusOnly: Decodable {
    var status: Int?
    var msg: String?
}

struct PlaudWorkspace: Decodable {
    var workspace_id: String
    var workspace_type: String?
    var api_domain: String?
    var name: String?
}

struct PlaudWorkspaceListResponse: Decodable {
    struct DataField: Decodable { var workspaces: [PlaudWorkspace]? }
    var status: Int?
    var msg: String?
    var data: DataField?
}

struct PlaudWorkspaceTokenResponse: Decodable {
    struct DataField: Decodable {
        var workspace_token: String?
        var wt_expires_at: Double?
    }
    var status: Int?
    var msg: String?
    var data: DataField?
}

public struct PlaudContentItem: Codable, Hashable, Sendable {
    public var data_id: String?
    public var data_type: String?
    public var data_title: String?
    public var task_status: Int?
    public var data_link: String?
}

public struct PlaudPreDownloadContent: Codable, Hashable, Sendable {
    public var data_id: String?
    public var data_content: String?
}

public struct PlaudFileDetail: Codable, Hashable, Sendable {
    public var file_id: String?
    public var file_name: String?
    public var content_list: [PlaudContentItem]?
    public var pre_download_content_list: [PlaudPreDownloadContent]?
}

struct PlaudFileDetailResponse: Decodable {
    var status: Int?
    var msg: String?
    var data: PlaudFileDetail?
}

public enum PlaudError: Error, CustomStringConvertible, Equatable {
    case notAToken
    case workspaceTokenPasted
    case expired(Date)
    case invalidToken
    case invalidAPIBase(String)
    case rateLimited
    case upstream(String)
    case api(status: Int, message: String)

    public var description: String {
        switch self {
        case .notAToken:
            return "That doesn't look like a Plaud token (expected a JWT starting with eyJ)."
        case .workspaceTokenPasted:
            return "That's a short-lived workspace token (~24h). Use your account token: localStorage 'pld_tokenstr' on web.plaud.ai, or sign in with the in-app web login."
        case .expired(let d):
            return "This Plaud token expired on \(d). Sign in again."
        case .invalidToken:
            return "Plaud rejected the token. Reconnect your Plaud account."
        case .invalidAPIBase(let s):
            return "Not a Plaud API host: \(s)"
        case .rateLimited:
            return "Plaud is rate-limiting requests. Try again in a minute."
        case .upstream(let s):
            return "Plaud is unavailable: \(s)"
        case .api(let status, let message):
            return "Plaud error \(status): \(message)"
        }
    }
}

/// JSONSerialization numbers differ across Foundation implementations (NSNumber vs Int/Double).
func jsonNumber(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
}

extension String {
    func trimmingTrailingSlashes() -> String {
        var s = self
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
