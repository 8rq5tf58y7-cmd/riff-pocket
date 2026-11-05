import XCTest
@testable import RiffCore

private func b64url(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func jwt(_ payload: String) -> String {
    "\(b64url(#"{"alg":"HS256","typ":"JWT"}"#)).\(b64url(payload)).signature"
}

final class PlaudTests: XCTestCase {
    func testUserTokenPassesShapeCheck() throws {
        let future = Int(Date().timeIntervalSince1970) + 86_400 * 300
        let ut = jwt(#"{"sub":"u1","exp":\#(future)}"#)
        XCTAssertEqual(try PlaudJWT.validateShape("Bearer \(ut)"), ut)
        XCTAssertEqual(try PlaudJWT.validateShape("\"\(ut)\""), ut) // JSON-quoted localStorage value
        XCTAssertEqual(PlaudJWT.expiry(ut).map { Int($0.timeIntervalSince1970) }, future)
    }

    func testWorkspaceTokenRejected() {
        let wt = jwt(#"{"sub":"u1","ut_ref":"abc","wid":"w1","exp":9999999999}"#)
        XCTAssertTrue(PlaudJWT.isWorkspaceToken(wt))
        XCTAssertThrowsError(try PlaudJWT.validateShape(wt)) { XCTAssertEqual($0 as? PlaudError, .workspaceTokenPasted) }
    }

    func testExpiredAndGarbageRejected() {
        XCTAssertThrowsError(try PlaudJWT.validateShape(jwt(#"{"exp":1000}"#)))
        XCTAssertThrowsError(try PlaudJWT.validateShape("not-a-token")) { XCTAssertEqual($0 as? PlaudError, .notAToken) }
    }

    func testRegionGuard() {
        XCTAssertTrue(PlaudRegion.isValidAPIBase("https://api-euc1.plaud.ai"))
        XCTAssertTrue(PlaudRegion.isValidAPIBase("https://api.plaud.cn"))
        XCTAssertFalse(PlaudRegion.isValidAPIBase("http://api.plaud.ai"))
        XCTAssertFalse(PlaudRegion.isValidAPIBase("https://plaud.ai.evil.com"))
        XCTAssertEqual(PlaudRegion.from(apiBase: "https://api-apse1.plaud.ai/"), .apac)
    }

    func testRecordingListDecodes() throws {
        let json = #"""
        {"status":0,"msg":"ok","data_file_total":1,"data_file_list":[
          {"id":"f1","filename":"Standup","filesize":1234,"filetype":"mp3","version_ms":1730000000123,
           "edit_time":1730000000,"is_trash":false,"start_time":1730000000000,"end_time":1730000600000,
           "duration":600000,"serial_number":"SN1","is_trans":true,"is_summary":false,"keywords":[],"extra":42}
        ]}
        """#
        let resp = try JSONDecoder().decode(PlaudRecordingsResponse.self, from: Data(json.utf8))
        let r = try XCTUnwrap(resp.data_file_list?.first)
        XCTAssertEqual(r.id, "f1")
        XCTAssertEqual(r.durationSeconds, 600)
        XCTAssertEqual(r.startedAt, Date(timeIntervalSince1970: 1_730_000_000))
        XCTAssertEqual(r.is_trans, true)
    }

    func testContentSelectionAndTranscriptParse() throws {
        let detail = PlaudFileDetail(
            file_id: "f1", file_name: "x",
            content_list: [
                PlaudContentItem(data_id: "sum_multi:1", data_type: "sum_multi_note", data_title: nil, task_status: 1, data_link: "https://s3/b"),
                PlaudContentItem(data_id: "source_transaction:1", data_type: "transaction", data_title: nil, task_status: 1, data_link: "https://s3/t"),
                PlaudContentItem(data_id: "auto_sum:1", data_type: "auto_sum_note", data_title: nil, task_status: 1, data_link: "https://s3/a"),
            ],
            pre_download_content_list: [PlaudPreDownloadContent(data_id: "auto_sum:1", data_content: ###"{"ai_content":"## Summary\nShipped it.","action_items":["Ryan: deploy"]}"###)]
        )
        let picked = PlaudContent.select(detail)
        XCTAssertEqual(picked.transcript?.data_id, "source_transaction:1")
        XCTAssertEqual(picked.summary?.data_id, "auto_sum:1") // primary beats sum_multi

        let summary = PlaudContent.parseSummary(try XCTUnwrap(PlaudContent.inline(detail, dataId: "auto_sum:1")))
        XCTAssertTrue(summary.contains("Shipped it."))
        XCTAssertTrue(summary.contains("- Ryan: deploy"))

        let raw: [[String: Any]] = [
            ["start_time": 0, "end_time": 1500, "speaker": 1, "content": "Hello"],
            ["start_time": 1500, "end_time": 4000, "speaker": "Ana", "content": "Hi there"],
        ]
        let t = PlaudContent.parseTranscript(raw)
        XCTAssertEqual(t.segments.count, 2)
        XCTAssertEqual(t.segments[0].speaker, "Speaker 1")
        XCTAssertEqual(t.segments[1].start, 1.5)
        XCTAssertEqual(PlaudContent.parseTranscript(["segments": raw]).segments.count, 2)
    }

    func testSyncPlan() {
        let remote = [
            PlaudRecording(id: "a", version_ms: 10, start_time: 2),
            PlaudRecording(id: "b", version_ms: 20, start_time: 1),
            PlaudRecording(id: "c", version_ms: 30, start_time: 3),
        ]
        let local = [PlaudSync.LocalState(plaudId: "a", version: 10),
                     PlaudSync.LocalState(plaudId: "c", version: 25),
                     PlaudSync.LocalState(plaudId: "z", version: 1)]
        let plan = PlaudSync.plan(remote: remote, local: local)
        XCTAssertEqual(plan.new.map(\.id), ["b"])
        XCTAssertEqual(plan.updated.map(\.id), ["c"])
        XCTAssertEqual(plan.goneRemotely, ["z"])
    }

    func testAudioSniffing() {
        XCTAssertEqual(PlaudClient.sniffAudioExtension(Data([0x4F, 0x67, 0x67, 0x53, 0, 0])), "ogg")
        XCTAssertEqual(PlaudClient.sniffAudioExtension(Data([0x49, 0x44, 0x33, 4])), "mp3")
        XCTAssertEqual(PlaudClient.sniffAudioExtension(Data([0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])), "m4a")
    }
}
