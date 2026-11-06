// Plaud "4.0" backend support — Swift port of Riffado PR #328 (src/lib/plaud/v4.ts, AGPL-3.0).
//
// Once Plaud migrates an account to 4.0, every legacy `/file/...` endpoint answers
// HTTP 200 `{"status":-1800907,"msg":"Account migrated to 4.0. Please update and reinitialize."}`
// while `/device/list` and the workspace-token endpoints keep working. Recordings are
// then read through `/file-app/v4/...` with the workspace token on the same regional host.
import Foundation

public enum PlaudV4 {
    public static let migratedStatus = -1_800_907

    /// True for the "Account migrated to 4.0" envelope.
    public static func isMigrated(status: Int?, msg: String?) -> Bool {
        if status == migratedStatus { return true }
        return msg?.range(of: "migrated to 4.0", options: .caseInsensitive) != nil
    }

    /// v4 exposes pre-migration files as `of_<legacy id>`; strip it so ids stay stable
    /// across the migration. New files (`f_…`) keep their v4 id.
    public static func recordingId(fromFileId fileId: String) -> String {
        fileId.hasPrefix("of_") ? String(fileId.dropFirst(3)) : fileId
    }

    public static func fileId(fromRecordingId id: String) -> String {
        (id.hasPrefix("f_") || id.hasPrefix("of_")) ? id : "of_\(id)"
    }

    static func map(_ item: RecordingItem) -> PlaudRecording {
        let start = item.created_at_show_ms ?? 0
        let version = item.version_ms ?? item.updated_at_show_ms ?? start
        var r = PlaudRecording(
            id: recordingId(fromFileId: item.file_id),
            filename: item.name,
            version_ms: version,
            start_time: start,
            duration: item.duration_ms ?? 0,
            is_trans: false,
            is_summary: false
        )
        r.edit_time = max(item.updated_at_show_ms ?? 0, version)
        r.end_time = start + (item.duration_ms ?? 0)
        r.source = "v4"
        return r
    }

    static func readyObject(_ detail: FileDetail?, type: String) -> FileObject? {
        detail?.objects?.first {
            $0.object_type == type && $0.task_status == 1
                && (!($0.content_url ?? "").isEmpty || !($0.content_id ?? "").isEmpty)
        }
    }

    /// Fills duration, start time and the transcript/summary flags the v4 listing lacks.
    static func apply(_ detail: FileDetail?, to recording: PlaudRecording) -> PlaudRecording {
        guard let detail = detail else { return recording }
        var r = recording
        if let start = detail.meta?.start_time { r.start_time = start }
        if let duration = detail.meta?.duration { r.duration = duration }
        if let sn = detail.meta?.serial_number, !sn.isEmpty { r.serial_number = sn }
        let audio = detail.objects?.first { $0.object_type == "AUDIO" }
        r.filesize = audio?.object_size ?? detail.meta?.size_bytes ?? r.filesize
        r.is_trans = readyObject(detail, type: "TRANSCRIPT") != nil
        r.is_summary = readyObject(detail, type: "SUMMARY") != nil
        return r
    }

    /// Expresses a v4 detail as the legacy `/file/detail` manifest so `PlaudContent`
    /// parses it unchanged (TRANSCRIPT → trans_result.json.gz, SUMMARY → ai_content.md.gz).
    static func legacyDetail(_ detail: FileDetail) -> PlaudFileDetail {
        let types = ["TRANSCRIPT": "transaction", "SUMMARY": "auto_sum_note"]
        let items: [PlaudContentItem] = (detail.objects ?? []).compactMap { o in
            guard let t = o.object_type, let dataType = types[t] else { return nil }
            return PlaudContentItem(data_id: o.content_id ?? o.object_id, data_type: dataType,
                                    data_title: nil, task_status: o.task_status, data_link: o.content_url)
        }
        return PlaudFileDetail(file_id: detail.meta?.file_id, file_name: nil,
                               content_list: items, pre_download_content_list: [])
    }

    // MARK: Wire types

    struct RecordingItem: Decodable {
        var node_id: String?
        var file_id: String
        var name: String?
        var duration_ms: Double?
        var created_at_show_ms: Double?
        var updated_at_show_ms: Double?
        var version_ms: Double?
    }

    struct RecordingsResponse: Decodable {
        struct DataField: Decodable {
            var items: [RecordingItem]?
            var next_cursor: String?
        }
        var status: Int?
        var msg: String?
        var data: DataField?
    }

    struct FileObject: Decodable {
        var object_id: String?
        var object_type: String?
        var content_id: String?
        var content_url: String?
        var mime_type: String?
        var object_size: Double?
        var task_status: Int?
    }

    struct FileMeta: Decodable {
        var file_id: String?
        var duration: Double?
        var size_bytes: Double?
        var start_time: Double?
        var serial_number: String?
        var version_ms: Double?
    }

    struct Node: Decodable {
        var node_id: String?
        var version_ms: Double?
    }

    struct FileDetail: Decodable {
        var node: Node?
        var meta: FileMeta?
        var objects: [FileObject]?
    }

    /// `/file-app/v4/nodes/rename` with a stale `origin_version`.
    public static let versionConflictStatus = -1_800_313

    struct FileDetailResponse: Decodable {
        var status: Int?
        var msg: String?
        var data: FileDetail?
    }

    struct ContentURLResponse: Decodable {
        struct DataField: Decodable { var url_map: [String: String]? }
        var status: Int?
        var data: DataField?
    }
}
