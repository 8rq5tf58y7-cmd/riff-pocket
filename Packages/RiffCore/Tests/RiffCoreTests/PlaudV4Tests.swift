import XCTest
@testable import RiffCore

final class PlaudV4Tests: XCTestCase {
    func testDetectsMigrationEnvelope() throws {
        XCTAssertTrue(PlaudV4.isMigrated(status: -1_800_907, msg: nil))
        XCTAssertTrue(PlaudV4.isMigrated(status: 1, msg: "Account migrated to 4.0. Please update and reinitialize."))
        XCTAssertFalse(PlaudV4.isMigrated(status: 0, msg: "success"))

        // The legacy list decoder must survive the envelope (no data_file_list).
        let json = #"{"status":-1800907,"msg":"Account migrated to 4.0. Please update and reinitialize."}"#
        let resp = try JSONDecoder().decode(PlaudRecordingsResponse.self, from: Data(json.utf8))
        XCTAssertNil(resp.data_file_list)
        XCTAssertTrue(PlaudV4.isMigrated(status: resp.status, msg: resp.msg))
    }

    func testIdMapping() {
        XCTAssertEqual(PlaudV4.recordingId(fromFileId: "of_abc123"), "abc123")
        XCTAssertEqual(PlaudV4.recordingId(fromFileId: "f_new1"), "f_new1")
        XCTAssertEqual(PlaudV4.fileId(fromRecordingId: "abc123"), "of_abc123")
        XCTAssertEqual(PlaudV4.fileId(fromRecordingId: "f_new1"), "f_new1")
    }

    func testListingMapsAndDetailHydrates() throws {
        let list = #"""
        {"status":0,"data":{"next_cursor":"c2","items":[
          {"node_id":"n1","file_id":"f_new1","name":"Standup","duration_ms":600000,
           "created_at_show_ms":1762300000000,"updated_at_show_ms":1762300900000,"version_ms":1762300800000}
        ]}}
        """#
        let resp = try JSONDecoder().decode(PlaudV4.RecordingsResponse.self, from: Data(list.utf8))
        XCTAssertEqual(resp.data?.next_cursor, "c2")
        let rec = PlaudV4.map(try XCTUnwrap(resp.data?.items?.first))
        XCTAssertEqual(rec.id, "f_new1")
        XCTAssertEqual(rec.source, "v4")
        XCTAssertEqual(rec.durationSeconds, 600)
        XCTAssertEqual(rec.versionMarker, 1_762_300_800_000)
        XCTAssertEqual(rec.is_trans, false)

        let detailJSON = #"""
        {"status":0,"data":{
          "meta":{"file_id":"f_new1","duration":601000,"start_time":1762300000000,"serial_number":"SN9"},
          "objects":[
            {"object_id":"o1","object_type":"AUDIO","content_id":"c-audio","content_url":"https://s3/audio.mp3","object_size":123456},
            {"object_id":"o2","object_type":"TRANSCRIPT","content_id":"c-t","content_url":"https://s3/trans_result.json.gz","task_status":1},
            {"object_id":"o3","object_type":"SUMMARY","content_id":"c-s","task_status":0}
          ]}}
        """#
        let detail = try XCTUnwrap(try JSONDecoder().decode(PlaudV4.FileDetailResponse.self, from: Data(detailJSON.utf8)).data)
        let hydrated = PlaudV4.apply(detail, to: rec)
        XCTAssertEqual(hydrated.is_trans, true)
        XCTAssertEqual(hydrated.is_summary, false) // not ready yet
        XCTAssertEqual(hydrated.durationSeconds, 601)
        XCTAssertEqual(hydrated.serial_number, "SN9")

        // Maps onto the legacy manifest so PlaudContent picks the transcript.
        let legacy = PlaudV4.legacyDetail(detail)
        let picked = PlaudContent.select(legacy)
        XCTAssertEqual(picked.transcript?.data_link, "https://s3/trans_result.json.gz")
        XCTAssertTrue(PlaudContent.isReady(picked.transcript))
        XCTAssertFalse(PlaudContent.isReady(picked.summary))
    }
}
