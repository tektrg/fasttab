import Foundation
import Testing
@testable import FastTab
import FastTabSync

/// Pure half of the live sync probe (`scripts/sync-probe.sh`).
struct SyncServerProbeTests {
    private let deviceID = "MAC-1"
    private let marker = "fasttab-sync-probe=abc123def456"

    private func tabRecord(_ name: String, url: String?, type: String = SyncedTab.recordType) -> SyncServerProbe.ServerRecordSummary {
        .init(recordType: type, recordName: name, browserName: "Safari", url: url)
    }

    // MARK: - Request parsing (untrusted input)

    @Test func parsesValidRequest() {
        let request = SyncServerProbe.parseRequest(userInfo: ["requestID": "A1-b2", "urlMarker": marker])
        #expect(request == .init(requestID: "A1-b2", urlMarker: marker))
    }

    @Test func rejectsMissingOrWrongTypedFields() {
        #expect(SyncServerProbe.parseRequest(userInfo: nil) == nil)
        #expect(SyncServerProbe.parseRequest(userInfo: ["requestID": "A1"]) == nil)
        #expect(SyncServerProbe.parseRequest(userInfo: ["requestID": 5, "urlMarker": marker]) == nil)
    }

    @Test func rejectsRequestIDsOutsideTheSafeAlphabet() {
        for badID in ["", "a/b", "../x", "$(echo INJECTED)", "id with space", String(repeating: "a", count: 65), "é"] {
            #expect(SyncServerProbe.parseRequest(userInfo: ["requestID": badID, "urlMarker": marker]) == nil, "\(badID)")
        }
    }

    /// A short or generic marker (e.g. "https://www.") would turn the answer
    /// into a dump of real tab URLs; only the probe's own key may match.
    @Test func rejectsMarkersThatWouldMatchTooBroadly() {
        for badMarker in [
            "", "https", "example.com", "has space in it ok", String(repeating: "m", count: 201),
            "https://www.", "://github.com/", "fasttab-sync-probe=",
        ] {
            #expect(SyncServerProbe.parseRequest(userInfo: ["requestID": "r1", "urlMarker": badMarker]) == nil, "\(badMarker)")
        }
    }

    // MARK: - Response

    @Test func listsOnlyThisDevicesTabRecordsContainingTheMarker() {
        let records = [
            tabRecord("MAC-1_Safari_probe", url: "https://example.com/?\(marker)"),
            tabRecord("MAC-1_Safari_other", url: "https://news.example.org/"),
            tabRecord("MAC-2_Safari_probe", url: "https://example.com/?\(marker)"),
            tabRecord("MAC-1", url: nil, type: SyncedDevice.recordType),
            tabRecord("MAC-1_Safari_nourl", url: nil),
        ]
        let response = SyncServerProbe.makeResponse(
            request: .init(requestID: "r1", urlMarker: marker),
            deviceID: deviceID,
            syncHealth: .ok,
            outcome: .ok,
            serverRecords: records,
            completedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(response.matchingTabs.map(\.recordName) == ["MAC-1_Safari_probe"])
        #expect(response.thisDeviceTabRecordCount == 3)
        #expect(response.syncHealth == "ok")
        #expect(response.requestID == "r1")
    }

    /// A device ID that prefixes another's must not claim its records.
    @Test func deviceOwnershipNeedsTheSeparator() {
        let other = tabRecord("MAC-10_Safari_x", url: "https://example.com/?\(marker)")
        #expect(!SyncServerProbe.isThisDevicesTabRecord(other, deviceID: "MAC-1"))
        #expect(SyncServerProbe.isThisDevicesTabRecord(other, deviceID: "MAC-10"))
    }

    @Test func healthLabelsAreStable() {
        #expect(SyncServerProbe.healthLabel(.ok) == "ok")
        #expect(SyncServerProbe.healthLabel(.noAccount) == "no-account")
        #expect(SyncServerProbe.healthLabel(.failing("quota")) == "failing: quota")
    }

    // MARK: - Zone mirror (the probe's own change feed)

    /// A tab closed on the Mac arrives as a deletion; a positional record name
    /// reused for another tab arrives as a modification with a new URL. Either
    /// way the marker must leave the answer.
    @Test func mirrorDropsDeletedAndOverwrittenMarkerRecords() {
        let request = SyncServerProbe.Request(requestID: "r3", urlMarker: marker)
        func matches(_ mirror: SyncServerProbe.ZoneMirror) -> [String] {
            SyncServerProbe.makeResponse(
                request: request, deviceID: deviceID, syncHealth: .ok, outcome: .ok,
                serverRecords: mirror.records, completedAt: Date()
            ).matchingTabs.map(\.recordName)
        }
        var mirror = SyncServerProbe.ZoneMirror()
        mirror.apply(modified: [
            tabRecord("MAC-1_Safari_win1_idx0", url: "https://example.com/?\(marker)"),
            tabRecord("MAC-1_Safari_win0_idx0", url: "https://news.example.org/"),
        ], deletedRecordNames: [])
        #expect(matches(mirror) == ["MAC-1_Safari_win1_idx0"])

        mirror.apply(modified: [tabRecord("MAC-1_Safari_win1_idx0", url: "https://other.example.org/")], deletedRecordNames: [])
        #expect(matches(mirror).isEmpty)

        mirror.apply(modified: [tabRecord("MAC-1_Safari_win2_idx0", url: "https://example.com/?\(marker)")], deletedRecordNames: [])
        mirror.apply(modified: [], deletedRecordNames: ["MAC-1_Safari_win2_idx0", "never-seen"])
        #expect(matches(mirror).isEmpty)
        #expect(mirror.records.count == 2)
    }

    // MARK: - Answer file

    @Test func answerFileIsOwnerOnlyAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-probe-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = SyncServerProbe.responseFileURL(fastTabSupportDirectory: root)
        let response = SyncServerProbe.makeResponse(
            request: .init(requestID: "r2", urlMarker: marker),
            deviceID: deviceID,
            syncHealth: .ok,
            outcome: .zoneMissing,
            serverRecords: [],
            completedAt: Date(timeIntervalSince1970: 1_000)
        )
        try SyncServerProbe.writeResponse(response, to: fileURL)

        let filePermissions = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] as? Int
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(filePermissions == 0o600)
        #expect(directoryPermissions == 0o700)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SyncServerProbe.Response.self, from: Data(contentsOf: fileURL))
        #expect(decoded == response)
        #expect(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains("\"zone-missing\""))
    }
}
