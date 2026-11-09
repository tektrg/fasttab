import CloudKit
import Foundation
import Testing
@testable import FastTabSync

/// Phone reading activity → CloudKit → the Mac's on-disk mirror (the reading connector's
/// source for pages read on the phone, listed or not).
@MainActor
@Suite("Reading activity sync (phone → Mac mirror)")
struct ReadingActivitySyncTests {
    final class PhoneStore: ReadingActivitySyncStore {
        var byID: [String: ReadingActivity] = [:]
        func readingActivitiesForSync() -> [ReadingActivity] { Array(byID.values) }
        func applyRemoteReadingActivities(_ activities: [ReadingActivity]) {
            for a in activities { byID[a.id] = byID[a.id].map { ReadingActivity.merge($0, a) } ?? a }
        }
    }

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)/\(name)")
    }

    @Test func mergeIsSymmetricNewestWinsAndKeepsTitle() {
        let old = ReadingActivity(url: "https://a.com/x", title: "Title", progress: 0.9, lastReadAt: t0)
        let new = ReadingActivity(url: "https://a.com/x", title: nil, progress: 0.3, lastReadAt: t0.addingTimeInterval(60))
        #expect(ReadingActivity.merge(old, new) == ReadingActivity.merge(new, old))
        let merged = ReadingActivity.merge(old, new)
        #expect(merged.progress == 0.3)
        #expect(merged.title == "Title")
    }

    @Test func idMatchesTheListItemIDForTheSameLink() {
        let a = ReadingActivity(url: "https://a.com/x?utm_source=z", progress: 0.5, lastReadAt: t0)
        #expect(a.id == FastTabListLibrary.itemID(for: "https://a.com/x"))
    }

    @Test func recordRoundTripKeepsTheRecordNameAsIdentity() throws {
        let a = ReadingActivity(url: "https://a.com/x", title: "T", progress: 0.42, lastReadAt: t0)
        let record = SyncedReadingActivity(a).toRecord(zoneID: SyncConstants.readerZoneID)
        #expect(record.recordType == "ReadingActivity")
        #expect(record.recordID.recordName == "ra|" + a.id)
        let back = try #require(SyncedReadingActivity(from: record))
        #expect(back.activity == a)
        #expect(ReadingActivitySyncBridge.handles(record.recordType))
        #expect(!ReaderSyncBridge.handles(record.recordType))
        #expect(!FastTabListSyncBridge.handles(record.recordType))
    }

    @Test func phoneSendsOnceThenOnlyChangesAndMacMirrorsToDisk() throws {
        let phone = PhoneStore()
        let phoneBridge = ReadingActivitySyncBridge(ledgerURL: temp("phone.json"), store: phone)
        let a = ReadingActivity(url: "https://a.com/x", title: "A", progress: 0.4, lastReadAt: t0)
        phone.byID[a.id] = a

        let first = phoneBridge.pendingSaves()
        #expect(first.count == 1)
        phoneBridge.didSave(first)
        #expect(phoneBridge.pendingSaves().isEmpty)

        let mirrorURL = temp("activity.json")
        let mirror = ReadingActivityMirror(fileURL: mirrorURL)
        let macBridge = ReadingActivitySyncBridge(ledgerURL: temp("mac.json"), store: mirror)
        macBridge.absorb(first)
        #expect(macBridge.pendingSaves().isEmpty, "the Mac never sends activity")
        #expect(ReadingActivityMirror.load(fileURL: mirrorURL) == [a])

        // Further reading on the phone: one new save, the Mac's copy moves forward.
        var later = a
        later.progress = 1
        later.lastReadAt = t0.addingTimeInterval(120)
        phone.byID[a.id] = later
        let second = phoneBridge.pendingSaves()
        #expect(second.count == 1)
        macBridge.absorb(second)
        #expect(ReadingActivityMirror.load(fileURL: mirrorURL).first?.progress == 1)

        // A stale copy arriving late never moves the mirror back.
        macBridge.absorb(first)
        #expect(ReadingActivityMirror.load(fileURL: mirrorURL).first?.progress == 1)
        // A fresh process reads the same file.
        #expect(ReadingActivityMirror(fileURL: mirrorURL).activities.first?.progress == 1)
    }

    @Test func conflictMergesWithTheServerCopy() throws {
        let phone = PhoneStore()
        let bridge = ReadingActivitySyncBridge(ledgerURL: temp("p.json"), store: phone)
        let mine = ReadingActivity(url: "https://a.com/x", progress: 0.7, lastReadAt: t0.addingTimeInterval(10))
        let theirs = ReadingActivity(url: "https://a.com/x", title: "From iPad", progress: 0.2, lastReadAt: t0)
        phone.byID[mine.id] = mine
        let serverRecord = SyncedReadingActivity(theirs).toRecord(zoneID: SyncConstants.readerZoneID)
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord])
        let outcome = bridge.outcome(ofFailedSave: SyncedReadingActivity(mine).toRecord(zoneID: SyncConstants.readerZoneID), error: error)
        guard case .retry(let retry) = outcome else { Issue.record("expected retry, got \(outcome)"); return }
        let sent = try #require(SyncedReadingActivity(from: retry))
        #expect(sent.activity.progress == 0.7)
        #expect(sent.activity.title == "From iPad")
        #expect(phone.byID[mine.id]?.title == "From iPad")
    }

    @Test func otherRecordTypesAreNotThisBridgesBusiness() {
        let bridge = ReadingActivitySyncBridge(ledgerURL: temp("p.json"), store: PhoneStore())
        let list = SyncedListItem(SavedOnIPhoneLink(id: "x", url: "https://a.com")).toRecord(zoneID: SyncConstants.readerZoneID)
        guard case .notReader = bridge.outcome(ofFailedSave: list, error: CKError(.serverRecordChanged)) else {
            Issue.record("list records must pass through"); return
        }
    }

    @Test func mirrorKeepsOnlyTheNewestEntriesPastTheCap() {
        let url = temp("activity.json")
        let mirror = ReadingActivityMirror(fileURL: url)
        let many = (0..<(ReadingActivityMirror.maxEntries + 3)).map {
            ReadingActivity(url: "https://a.com/\($0)", progress: 0.5, lastReadAt: t0.addingTimeInterval(TimeInterval($0)))
        }
        mirror.applyRemoteReadingActivities(many)
        let stored = ReadingActivityMirror.load(fileURL: url)
        #expect(stored.count == ReadingActivityMirror.maxEntries)
        #expect(stored.first?.url == "https://a.com/\(ReadingActivityMirror.maxEntries + 2)")
        #expect(!stored.contains { $0.url == "https://a.com/0" })
    }

    @Test func removeAllForgetsThePreviousAccount() {
        let url = temp("activity.json")
        let mirror = ReadingActivityMirror(fileURL: url)
        mirror.applyRemoteReadingActivities([ReadingActivity(url: "https://a.com/x", progress: 1, lastReadAt: t0)])
        mirror.removeAll()
        #expect(mirror.activities.isEmpty)
        #expect(ReadingActivityMirror.load(fileURL: url).isEmpty)
    }
}
