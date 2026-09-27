import Testing
import CloudKit
import Foundation
@testable import FastTab
@testable import FastTabSync

@Suite("SyncedTabStats wire model")
struct SyncedTabStatsTests {
    private let zoneID = CKRecordZone.ID(zoneName: "StateZone", ownerName: CKCurrentUserDefaultName)

    private func sampleStats() -> SyncedTabStats {
        var hours = Array(repeating: 0, count: 24)
        hours[9] = 3
        return SyncedTabStats(
            deviceID: "mac-1",
            timeZoneID: "Asia/Ho_Chi_Minh",
            days: [TabDay(day: "2026-09-27", opened: 3, closed: 1, avgOpen: 12.5, maxOpen: 15, openedByHour: hours)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("Round-trips through a CloudKit record with the days encrypted")
    func recordRoundTrip() throws {
        let stats = sampleStats()
        let record = try #require(stats.toRecord(zoneID: zoneID))
        #expect(record.recordID.recordName == "mac-1|tabstats")
        #expect(record.recordType == "SyncedTabStats")
        #expect(record["daysData"] == nil)
        #expect(record.encryptedValues["daysData"] != nil)
        #expect(SyncedTabStats(from: record) == stats)
    }

    @Test("Applying updates a fetched record in place")
    func applyingPreservesRecord() throws {
        let record = try #require(sampleStats().toRecord(zoneID: zoneID))
        let newer = SyncedTabStats(deviceID: "mac-1", timeZoneID: "UTC", days: [])
        #expect(newer.applying(to: record) === record)
        #expect(record["timeZoneID"] as? String == "UTC")
    }

    @Test("Refuses a record of another device's name")
    func applyingRejectsForeignRecord() throws {
        let other = try #require(SyncedTabStats(deviceID: "mac-2", timeZoneID: "UTC", days: []).toRecord(zoneID: zoneID))
        #expect(sampleStats().applying(to: other) == nil)
    }

    @Test("Decodes a day missing newer fields, and pads the hour histogram to 24")
    func tolerantDecoding() throws {
        let json = #"[{"day":"2026-09-27","opened":2,"openedByHour":[1,1],"futureField":true}]"#
        let days = try JSONDecoder().decode([TabDay].self, from: Data(json.utf8))
        #expect(days.count == 1)
        #expect(days[0].opened == 2)
        #expect(days[0].closed == 0)
        #expect(days[0].avgOpen == 0)
        #expect(days[0].openedByHour.count == 24)
        #expect(days[0].openedByHour.prefix(2) == [1, 1])
    }

    @Test("Conflict retry reapplies the digest onto the server record")
    func conflictRetry() throws {
        let intended = try #require(sampleStats().toRecord(zoneID: zoneID))
        let server = CKRecord(recordType: SyncedTabStats.recordType, recordID: intended.recordID)
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        let retry = try #require(SyncService.recordForRetry(intendedRecord: intended, error: error))
        #expect(retry === server)
        #expect(SyncedTabStats(from: retry) == sampleStats())
    }
}

@Suite("Tab stats publish gate")
struct TabStatsPublishGateTests {
    @Test("Checks at most hourly, and immediately when never checked")
    func hourlyGate() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SyncService.isTabStatsCheckDue(lastCheckedAt: nil, now: now))
        #expect(!SyncService.isTabStatsCheckDue(lastCheckedAt: now.addingTimeInterval(-59 * 60), now: now))
        #expect(SyncService.isTabStatsCheckDue(lastCheckedAt: now.addingTimeInterval(-60 * 60), now: now))
    }

    @Test("Fingerprint changes with the digest and the time zone only")
    func fingerprint() {
        let days = [TabDay(day: "2026-09-27", opened: 1)]
        let same = SyncService.tabStatsFingerprint(days: days, timeZoneID: "UTC")
        #expect(same == SyncService.tabStatsFingerprint(days: [TabDay(day: "2026-09-27", opened: 1)], timeZoneID: "UTC"))
        #expect(same != SyncService.tabStatsFingerprint(days: [TabDay(day: "2026-09-27", opened: 2)], timeZoneID: "UTC"))
        #expect(same != SyncService.tabStatsFingerprint(days: days, timeZoneID: "Asia/Ho_Chi_Minh"))
    }
}
