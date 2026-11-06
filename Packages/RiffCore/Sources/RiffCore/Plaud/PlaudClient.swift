// Swift port of Riffado's src/lib/plaud/client.ts + workspace.ts (AGPL-3.0).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to Plaud's cloud API with your long-lived user token (UT).
/// Data calls use a short-lived workspace token (WT) minted from the UT,
/// falling back to the UT itself if minting fails — same as Riffado.
public actor PlaudClient {
    /// Plaud rejects non-browser user agents (Riffado regression #132).
    public static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    public let credentials: PlaudCredentials
    private let http: HTTPClient
    private var workspaceToken: String?
    private var workspaceTokenExpiry: Date?
    private var useUserTokenFallback = false
    public private(set) var workspaceId: String?

    public init(credentials: PlaudCredentials, http: HTTPClient = HTTPClient()) {
        self.credentials = credentials
        self.http = http
        self.workspaceId = credentials.workspaceId
    }

    // MARK: Low-level

    private func makeRequest(_ path: String, method: String = "GET", bearer: String, body: Data? = nil) throws -> URLRequest {
        guard PlaudRegion.isValidAPIBase(credentials.apiBase) else { throw PlaudError.invalidAPIBase(credentials.apiBase) }
        var req = URLRequest(url: try makeURL(credentials.apiBase, path))
        req.httpMethod = method
        req.timeoutInterval = 60
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(PlaudClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        return req
    }

    /// Retries 429 / 5xx / network errors with exponential backoff (1s, 2s, 4s).
    private func send<T: Decodable>(_ build: () throws -> URLRequest, as type: T.Type) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await http.sendJSON(try build(), as: T.self)
            } catch HTTPError.status(let code, let body) {
                if code == 401 { throw PlaudError.invalidToken }
                let retryable = code == 429 || (500..<600).contains(code)
                if retryable && attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (1 << attempt)))
                    attempt += 1
                    continue
                }
                if code == 429 { throw PlaudError.rateLimited }
                if code >= 500 { throw PlaudError.upstream("HTTP \(code)") }
                throw PlaudError.api(status: code, message: body)
            } catch let error as URLError {
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (1 << attempt)))
                    attempt += 1
                    continue
                }
                throw PlaudError.upstream(error.localizedDescription)
            }
        }
    }

    // MARK: Workspace token

    private func ensureWorkspaceToken() async {
        if useUserTokenFallback { return }
        if let _ = workspaceToken, let exp = workspaceTokenExpiry, exp > Date().addingTimeInterval(300) { return }
        if workspaceToken != nil && workspaceTokenExpiry == nil { return }
        do {
            try await mintWorkspaceToken()
        } catch {
            useUserTokenFallback = true
        }
    }

    private func mintWorkspaceToken() async throws {
        let ut = credentials.userToken
        if workspaceId == nil {
            let list = try await send({
                try makeRequest("team-app/workspaces/list?need_personal_workspace=true", bearer: ut)
            }, as: PlaudWorkspaceListResponse.self)
            guard list.status == 0, let spaces = list.data?.workspaces, !spaces.isEmpty else {
                throw PlaudError.api(status: list.status ?? -1, message: list.msg ?? "No Plaud workspaces")
            }
            workspaceId = (spaces.first { $0.workspace_type == "0" } ?? spaces[0]).workspace_id
        }
        guard let wid = workspaceId else { return }
        let escaped = wid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? wid
        let resp = try await send({
            try makeRequest("user-app/auth/workspace/token/\(escaped)", method: "POST", bearer: ut, body: Data("{}".utf8))
        }, as: PlaudWorkspaceTokenResponse.self)
        guard resp.status == 0, let wt = resp.data?.workspace_token else {
            workspaceId = nil // stale cached id; relist next time
            throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Could not mint workspace token")
        }
        workspaceToken = wt
        workspaceTokenExpiry = resp.data?.wt_expires_at.map { Date(timeIntervalSince1970: $0 > 1e12 ? $0 / 1000 : $0) }
            ?? PlaudJWT.expiry(wt)
    }

    private func dataRequest<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, as type: T.Type) async throws -> T {
        await ensureWorkspaceToken()
        let bearer = workspaceToken ?? credentials.userToken
        return try await send({ try makeRequest(path, method: method, bearer: bearer, body: body) }, as: T.self)
    }

    // MARK: API

    public func listDevices() async throws -> [PlaudDevice] {
        let resp = try await dataRequest("device/list", as: PlaudDeviceListResponse.self)
        guard resp.status == 0, let devices = resp.data_devices else {
            throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Invalid device list")
        }
        return devices
    }

    // MARK: Plaud 4.0 mode

    /// Flipped on the first legacy call that answers "Account migrated to 4.0" (status -1800907).
    public private(set) var usingV4 = false
    private var v4ListCache: [PlaudRecording]?
    private var v4DetailCache: [String: PlaudV4.FileDetail] = [:]

    /// Legacy listing page. Returns nil (and switches to v4) for migrated accounts.
    private func legacyListPage(skip: Int, limit: Int) async throws -> (total: Int, items: [PlaudRecording])? {
        let path = "file/simple/web?skip=\(skip)&limit=\(limit)&is_trash=0&sort_by=edit_time&is_desc=true"
        let resp = try await dataRequest(path, as: PlaudRecordingsResponse.self)
        if let items = resp.data_file_list { return (resp.data_file_total ?? items.count, items) }
        if PlaudV4.isMigrated(status: resp.status, msg: resp.msg) {
            usingV4 = true
            return nil
        }
        throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Could not list recordings")
    }

    public func listAllRecordings(pageSize: Int = 200) async throws -> [PlaudRecording] {
        if !usingV4 {
            var all: [PlaudRecording] = []
            var skip = 0
            while let page = try await legacyListPage(skip: skip, limit: pageSize) {
                all += page.items
                skip += page.items.count
                if page.items.isEmpty || skip >= page.total { return all }
            }
        }
        return try await listAllRecordingsV4()
    }

    /// `/file-app/v4/recordings/all`, cursor-paginated, newest first.
    private func listAllRecordingsV4() async throws -> [PlaudRecording] {
        if let cached = v4ListCache { return cached }
        var out: [PlaudRecording] = []
        var cursor: String?
        for _ in 0..<400 {
            var path = "file-app/v4/recordings/all?sort_by=created&sort_order=desc&page_size=50"
            if let c = cursor, let enc = c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                path += "&cursor=\(enc)"
            }
            let resp = try await dataRequest(path, as: PlaudV4.RecordingsResponse.self)
            guard resp.status == 0, let items = resp.data?.items else {
                throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Invalid Plaud 4.0 recordings response")
            }
            out += items.map(PlaudV4.map)
            guard let next = resp.data?.next_cursor, !next.isEmpty, !items.isEmpty else { break }
            cursor = next
        }
        v4ListCache = out
        return out
    }

    private func v4Detail(recordingId: String) async throws -> PlaudV4.FileDetail {
        let fileId = PlaudV4.fileId(fromRecordingId: recordingId)
        if let cached = v4DetailCache[fileId] { return cached }
        let escaped = fileId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileId
        let resp = try await dataRequest("file-app/v4/files/detail/\(escaped)", as: PlaudV4.FileDetailResponse.self)
        guard resp.status == 0, let detail = resp.data else {
            throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Invalid Plaud 4.0 file detail")
        }
        v4DetailCache[fileId] = detail
        return detail
    }

    /// Presigned URLs for v4 content ids.
    private func v4ContentURLs(_ ids: [String]) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let body = try JSONSerialization.data(withJSONObject: ["content_ids": ids])
        let resp = try await dataRequest("file-app/v4/files/content/url", method: "POST", body: body,
                                         as: PlaudV4.ContentURLResponse.self)
        return resp.status == 0 ? (resp.data?.url_map ?? [:]) : [:]
    }

    /// Fills duration and transcript/summary flags for recordings listed via v4 (no-op otherwise).
    public func hydrate(_ recording: PlaudRecording) async throws -> PlaudRecording {
        guard recording.source == "v4" else { return recording }
        return PlaudV4.apply(try await v4Detail(recordingId: recording.id), to: recording)
    }

    /// Presigned download URL. `opus: false` gives a format AVFoundation/WhisperKit read directly
    /// (legacy accounts; Plaud 4.0 serves whatever its AUDIO object holds).
    public func audioURL(fileId: String, opus: Bool = false) async throws -> URL {
        if !usingV4 {
            let resp = try await dataRequest("file/temp-url/\(fileId)?is_opus=\(opus ? 1 : 0)", as: PlaudTempURLResponse.self)
            if let s = (opus ? resp.temp_url_opus : nil) ?? resp.temp_url, let url = URL(string: s) { return url }
            guard PlaudV4.isMigrated(status: resp.status, msg: resp.msg) else {
                throw PlaudError.api(status: resp.status ?? -1, message: "No download URL for \(fileId)")
            }
            usingV4 = true
        }
        let detail = try await v4Detail(recordingId: fileId)
        let audio = detail.objects?.first { $0.object_type == "AUDIO" }
        if let s = audio?.content_url, let url = URL(string: s) { return url }
        if let cid = audio?.content_id, let s = try await v4ContentURLs([cid])[cid], let url = URL(string: s) { return url }
        throw PlaudError.api(status: -1, message: "Plaud has no downloadable audio for this recording yet.")
    }

    /// Downloads the recording into `directory`; returns the saved file URL.
    public func downloadAudio(fileId: String, into directory: URL) async throws -> URL {
        let remote = try await audioURL(fileId: fileId)
        var req = URLRequest(url: remote)
        req.timeoutInterval = 600
        let data = try await http.send(req)
        var ext = remote.pathExtension.lowercased()
        if ext.isEmpty || ext.count > 5 { ext = Self.sniffAudioExtension(data) }
        let dest = directory.appendingPathComponent("plaud-\(fileId).\(ext)")
        try data.write(to: dest, options: .atomic)
        return dest
    }

    /// Renames the recording in Plaud too (legacy PATCH /file/{id}; Plaud 4.0 nodes/rename with
    /// origin_version, refetching and retrying once on a version conflict — as Riffado PR #328 does).
    public func rename(fileId: String, to name: String) async throws {
        if !usingV4 {
            let body = try JSONSerialization.data(withJSONObject: ["filename": name])
            let resp = try await dataRequest("file/\(fileId)", method: "PATCH", body: body, as: PlaudStatusOnly.self)
            if resp.status == 0 || resp.status == nil { return }
            guard PlaudV4.isMigrated(status: resp.status, msg: resp.msg) else {
                throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Rename failed")
            }
            usingV4 = true
        }
        for attempt in 0..<2 {
            v4DetailCache[PlaudV4.fileId(fromRecordingId: fileId)] = nil // need the current version
            let detail = try await v4Detail(recordingId: fileId)
            guard let nodeId = detail.node?.node_id else {
                throw PlaudError.api(status: -1, message: "Plaud didn't return a node to rename")
            }
            var payload: [String: Any] = ["name": name]
            if let v = detail.node?.version_ms { payload["origin_version"] = v }
            let escaped = nodeId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? nodeId
            let resp = try await dataRequest("file-app/v4/nodes/rename/\(escaped)", method: "PATCH",
                                             body: try JSONSerialization.data(withJSONObject: payload),
                                             as: PlaudStatusOnly.self)
            if resp.status == 0 { return }
            if resp.status == PlaudV4.versionConflictStatus && attempt == 0 { continue }
            throw PlaudError.api(status: resp.status ?? -1, message: resp.msg ?? "Rename failed")
        }
    }

    public func fileDetail(fileId: String) async throws -> PlaudFileDetail? {
        if !usingV4 {
            let resp = try await dataRequest("file/detail/\(fileId)", as: PlaudFileDetailResponse.self)
            guard PlaudV4.isMigrated(status: resp.status, msg: resp.msg) else { return resp.data }
            usingV4 = true
        }
        // Plaud 4.0: same gzip payloads, reached through the v4 detail; resolve missing URLs.
        var detail = try await v4Detail(recordingId: fileId)
        let missing = (detail.objects ?? []).filter {
            ($0.object_type == "TRANSCRIPT" || $0.object_type == "SUMMARY")
                && ($0.content_url ?? "").isEmpty && !($0.content_id ?? "").isEmpty
        }.compactMap(\.content_id)
        if !missing.isEmpty {
            let urls = try await v4ContentURLs(missing)
            detail.objects = detail.objects?.map { o in
                var o = o
                if (o.content_url ?? "").isEmpty, let cid = o.content_id, let u = urls[cid] { o.content_url = u }
                return o
            }
        }
        return PlaudV4.legacyDetail(detail)
    }

    /// Presigned content (transcript/summary JSON); no auth header; may be gzip.
    public func fetchContentLink(_ link: String) async throws -> Any {
        guard let url = URL(string: link) else { throw HTTPError.invalidURL(link) }
        let raw = try await http.send(URLRequest(url: url))
        let data = Gzip.isGzip(raw) ? (try Gzip.decompress(raw)) : raw
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) { return json }
        return String(decoding: data, as: UTF8.self)
    }

    /// Plaud's own transcript + summary for a recording, if Plaud has processed them.
    public func plaudContent(fileId: String) async throws -> PlaudContent.Parsed {
        guard let detail = try await fileDetail(fileId: fileId) else { return .init() }
        let picked = PlaudContent.select(detail)
        var result = PlaudContent.Parsed()
        if let t = picked.transcript {
            if let inline = PlaudContent.inline(detail, dataId: t.data_id) {
                result.transcript = PlaudContent.parseTranscript(inline)
            } else if PlaudContent.isReady(t), let link = t.data_link {
                result.transcript = PlaudContent.parseTranscript(try await fetchContentLink(link))
            }
        }
        if let s = picked.summary {
            if let inline = PlaudContent.inline(detail, dataId: s.data_id) {
                result.summary = PlaudContent.parseSummary(inline)
            } else if PlaudContent.isReady(s), let link = s.data_link {
                result.summary = PlaudContent.parseSummary(try await fetchContentLink(link))
            }
        }
        return result
    }

    // MARK: Connect / validate

    /// Same validation Riffado runs before storing a token: mint WT via workspaces, then /device/list.
    public static func connect(token raw: String, apiBase: String) async throws -> (PlaudCredentials, [PlaudDevice]) {
        let token = try PlaudJWT.validateShape(raw)
        let base = apiBase.trimmingTrailingSlashes()
        guard PlaudRegion.isValidAPIBase(base) else { throw PlaudError.invalidAPIBase(base) }
        let client = PlaudClient(credentials: PlaudCredentials(userToken: token, apiBase: base))
        let devices = try await client.listDevices()
        let wid = await client.workspaceId
        return (PlaudCredentials(userToken: token, apiBase: base, workspaceId: wid), devices)
    }

    /// For tokens captured without knowing the region: try each region until one accepts it.
    public static func connectDetectingRegion(token: String, preferred: PlaudRegion? = nil) async throws -> (PlaudCredentials, [PlaudDevice]) {
        var order = PlaudRegion.allCases
        if let p = preferred { order.removeAll { $0 == p }; order.insert(p, at: 0) }
        var lastError: Error = PlaudError.invalidToken
        for region in order {
            do { return try await connect(token: token, apiBase: region.apiBase) }
            catch let e as PlaudError where e == .notAToken || e == .workspaceTokenPasted { throw e }
            catch { lastError = error }
        }
        throw lastError
    }

    static func sniffAudioExtension(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 4, b[0] == 0x4F, b[1] == 0x67, b[2] == 0x67, b[3] == 0x53 { return "ogg" }            // OggS
        if b.count >= 3, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return "mp3" }                           // ID3
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return "mp3" }                                // MPEG frame
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "m4a" }            // ftyp
        if b.count >= 4, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 { return "wav" }             // RIFF
        return "mp3"
    }
}
