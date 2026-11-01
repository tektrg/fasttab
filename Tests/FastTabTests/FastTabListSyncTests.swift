import CloudKit
import Foundation
import Testing
@testable import FastTabSync

/// FastTab List sync: devices are bridges over in-memory libraries, with a fake
/// CloudKit zone in between that applies saves/deletes and hands records back.
@MainActor
@Suite("FastTab List sync (merge, deletes, ledger)")
struct FastTabListSyncTests {
    final class MemoryList: FastTabListSyncStore {
        var library = FastTabListLibrary()
        func listItemsForSync() -> [SavedOnIPhoneLink] { Array(library.itemsByID.values) }
        func applyRemoteListItem(_ item: SavedOnIPhoneLink) -> SavedOnIPhoneLink { library.applyRemote(item) }
        func removeRemoteListItem(id: String) { library.removeRemote(id: id, now: Date(timeIntervalSince1970: 1_900_000_000)) }
    }

    /// The server: record name → latest record; deletions are reported to fetchers.
    final class FakeZone {
        var records: [String: CKRecord] = [:]
        var deleted: [CKRecord.ID] = []
    }

    struct Device {
        let list = MemoryList()
        let ledgerURL: URL
        let bridge: FastTabListSyncBridge

        @MainActor init(ledgerURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("list-sync-\(UUID().uuidString)/ledger.json")) {
            self.ledgerURL = ledgerURL
            bridge = FastTabListSyncBridge(ledgerURL: ledgerURL, store: list)
        }

        /// Sends what's pending; the zone accepts everything (last write wins, as a
        /// conflict-free save would) and CloudKit confirms.
        @MainActor @discardableResult
        func send(to zone: FakeZone) -> (saves: [CKRecord], deletes: [CKRecord.ID]) {
            let pending = bridge.pendingChanges()
            for record in pending.saves { zone.records[record.recordID.recordName] = record }
            for id in pending.deletes {
                zone.records[id.recordName] = nil
                zone.deleted.append(id)
            }
            bridge.didSave(pending.saves)
            bridge.didDelete(pending.deletes)
            return pending
        }

        @MainActor func fetch(from zone: FakeZone) {
            bridge.absorb(Array(zone.records.values))
            bridge.absorbDeletions(zone.deleted)
        }
    }

    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    func link(_ url: String, title: String? = nil, at time: TimeInterval = 0) -> SavedOnIPhoneLink {
        SavedOnIPhoneLink(url: url, title: title, savedAt: at(time))
    }

    // MARK: - Merge rules

    @Test func mergeIsSymmetricAndPicksEachFieldOnItsOwnClock() {
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")
        var phone = SavedOnIPhoneLink(id: id, url: "https://a.com/x", title: "Old", savedAt: at(0))
        var pad = phone
        // Phone reads to 50% later than the pad's title edit…
        phone.progress = 0.5; phone.progressUpdatedAt = at(20); phone.updatedAt = at(20)
        // …but the pad trashed + renamed it even later.
        pad.title = "New"; pad.deletedAt = at(30); pad.updatedAt = at(30)
        pad.progress = 0.2; pad.progressUpdatedAt = at(10)

        let merged = FastTabListMerge.merge(phone, pad)
        #expect(merged == FastTabListMerge.merge(pad, phone), "order of arrival doesn't matter")
        #expect(merged.title == "New")
        #expect(merged.deletedAt == at(30))
        #expect(merged.progress == 0.5, "progress follows progressUpdatedAt, not updatedAt")
        #expect(merged.updatedAt == at(30))
        #expect(FastTabListMerge.merge(merged, merged) == merged)
    }

    @Test func markUnreadSticksAgainstAnOlderRead() {
        var library = FastTabListLibrary(items: [link("https://a.com/x")])
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")
        library.setRead(id: id, true, now: at(10))
        let readCopy = library.itemsByID[id]!
        library.setRead(id: id, false, now: at(20))
        let unreadCopy = library.itemsByID[id]!
        #expect(FastTabListMerge.merge(readCopy, unreadCopy).readAt == nil)
        #expect(FastTabListMerge.merge(unreadCopy, readCopy).readAt == nil)
    }

    @Test func restoreFromTrashWinsWhenNewer() {
        var library = FastTabListLibrary(items: [link("https://a.com/x")])
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")
        library.moveToTrash(id: id, now: at(10))
        let trashed = library.itemsByID[id]!
        library.restore(id: id, now: at(20))
        #expect(FastTabListMerge.merge(trashed, library.itemsByID[id]!).deletedAt == nil)
    }

    // MARK: - Two devices

    @Test func sameURLSavedOnTwoDevicesBecomesOneItem() {
        let zone = FakeZone(), phone = Device(), pad = Device()
        phone.list.library.save(link("https://Example.com/post?utm_source=x", title: "Phone"), now: at(1))
        pad.list.library.save(link("https://example.com/post#top", title: "Pad"), now: at(2))
        phone.send(to: zone)
        pad.fetch(from: zone)
        pad.send(to: zone)
        phone.fetch(from: zone)

        #expect(zone.records.count == 1)
        #expect(phone.list.library.itemsByID.count == 1)
        #expect(phone.list.library.liveItems.first?.title == "Pad", "newer edit wins")
        #expect(phone.list.library == pad.list.library)
        #expect(phone.bridge.pendingChanges().saves.isEmpty && pad.bridge.pendingChanges().saves.isEmpty,
                "converged: nothing left to send")
    }

    @Test func trashAndRestoreReachTheOtherDevice() {
        let zone = FakeZone(), phone = Device(), pad = Device()
        phone.list.library.save(link("https://a.com/x"), now: at(1))
        phone.send(to: zone); pad.fetch(from: zone)
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")

        pad.list.library.moveToTrash(id: id, now: at(5))
        pad.send(to: zone); phone.fetch(from: zone)
        #expect(phone.list.library.liveItems.isEmpty)
        #expect(phone.list.library.trashedItems.count == 1)

        phone.list.library.restore(id: id, now: at(9))
        phone.send(to: zone); pad.fetch(from: zone)
        #expect(pad.list.library.liveItems.count == 1)
    }

    @Test func purgeLeavesAMarkerThatHidesTheItemEverywhere() {
        let zone = FakeZone(), phone = Device(), pad = Device()
        phone.list.library.save(link("https://a.com/x", title: "Secret"), now: at(1))
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")
        phone.list.library.moveToTrash(id: id, now: at(2))
        phone.send(to: zone); pad.fetch(from: zone)

        pad.list.library.purgeExpiredTrash(now: at(2 + FastTabListLibrary.trashRetention + 1))
        let sent = pad.send(to: zone)
        #expect(sent.deletes.isEmpty, "the CloudKit record is kept as a marker, not deleted")
        let marker = SyncedListItem(from: zone.records.values.first!)!.item
        #expect(marker.isPurged && marker.title == nil && marker.url.isEmpty && marker.progress == 0)

        phone.fetch(from: zone)
        #expect(phone.list.library.liveItems.isEmpty && phone.list.library.trashedItems.isEmpty)
        #expect(phone.list.library.item(id: id) == nil, "markers are hidden")
        #expect(phone.bridge.pendingChanges().saves.isEmpty)
    }

    @Test func longOfflineDeviceEditAfterPurgeStaysPurged() {
        let zone = FakeZone(), phone = Device(), oldPad = Device()
        phone.list.library.save(link("https://a.com/x"), now: at(1))
        phone.send(to: zone); oldPad.fetch(from: zone)
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")

        // Phone trashes and later purges; the pad is offline the whole time…
        phone.list.library.moveToTrash(id: id, now: at(2))
        phone.list.library.purgeExpiredTrash(now: at(2 + FastTabListLibrary.trashRetention + 1))
        phone.send(to: zone)
        // …and edits its stale copy (read it, renamed it) well after the purge.
        let late = 3 + FastTabListLibrary.trashRetention + 100
        oldPad.list.library.recordProgress(url: "https://a.com/x", progress: 0.95, now: at(late))
        oldPad.list.library.setRead(id: id, false, now: at(late + 1))

        oldPad.fetch(from: zone)
        oldPad.send(to: zone)
        phone.fetch(from: zone)
        #expect(oldPad.list.library.item(id: id) == nil, "the marker beats the stale edit")
        #expect(phone.list.library.item(id: id) == nil)
        #expect(SyncedListItem(from: zone.records.values.first!)!.item.isPurged)
        #expect(FastTabListMerge.merge(phone.list.library.itemsByID[id]!, oldPad.list.library.itemsByID[id]!)
            == FastTabListMerge.merge(oldPad.list.library.itemsByID[id]!, phone.list.library.itemsByID[id]!))
    }

    @Test func explicitResaveAfterPurgeRestoresEverywhere() {
        let zone = FakeZone(), phone = Device(), pad = Device()
        phone.list.library.save(link("https://a.com/x", title: "Old"), now: at(1))
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")
        phone.list.library.moveToTrash(id: id, now: at(2))
        let purgeTime = 2 + FastTabListLibrary.trashRetention + 1
        phone.list.library.purgeExpiredTrash(now: at(purgeTime))
        phone.send(to: zone); pad.fetch(from: zone)

        pad.list.library.save(link("https://a.com/x", title: "Again", at: purgeTime + 50), now: at(purgeTime + 50))
        pad.send(to: zone); phone.fetch(from: zone)
        #expect(phone.list.library.liveItems.map(\.title) == ["Again"])
        #expect(phone.list.library.liveItems.first?.progress == 0, "a fresh item, not the old one")
    }

    @Test func deleteNowIsAMarkerTooAndIgnoresTheStaleServerCopy() {
        let zone = FakeZone(), phone = Device()
        phone.list.library.save(link("https://a.com/x"), now: at(1))
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")
        phone.list.library.moveToTrash(id: id, now: at(2))
        phone.send(to: zone)
        phone.list.library.deleteNow(id: id, now: at(3))

        phone.fetch(from: zone) // before the marker went out
        #expect(phone.list.library.item(id: id) == nil, "no resurrection from the server copy")
        #expect(phone.bridge.pendingChanges().saves.count == 1)
    }

    @Test func legacyCloudKitDeleteBecomesAMarker() {
        let phone = Device()
        phone.list.library.save(link("https://a.com/x"), now: at(1))
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")
        phone.bridge.absorbDeletions([CKRecord.ID(recordName: SyncedListItem.recordName(forItemID: id),
                                                  zoneID: phone.bridge.zoneID)])
        #expect(phone.list.library.item(id: id) == nil)
        #expect(phone.list.library.itemsByID[id]?.isPurged == true)
    }

    // MARK: - Durability

    @Test func offlineTrashSurvivesARelaunchAndGoesOut() {
        let zone = FakeZone()
        let ledgerURL = FileManager.default.temporaryDirectory.appendingPathComponent("list-sync-\(UUID().uuidString)/ledger.json")
        let phone = Device(ledgerURL: ledgerURL)
        phone.list.library.save(link("https://a.com/x"), now: at(1))
        phone.send(to: zone)
        let id = FastTabListLibrary.itemID(for: "https://a.com/x")

        // Offline: trash, then the app is killed. The list itself is persisted by its own
        // file store; only the bridge (and its ledger) is rebuilt.
        phone.list.library.moveToTrash(id: id, now: at(5))
        let relaunched = Device(ledgerURL: ledgerURL)
        relaunched.list.library = phone.list.library

        let sent = relaunched.send(to: zone)
        #expect(sent.saves.count == 1)
        #expect(SyncedListItem(from: zone.records.values.first!)?.item.isTrashed == true)
    }

    @Test func unconfirmedSendIsResentAndAReplayIsHarmless() {
        let zone = FakeZone(), phone = Device(), pad = Device()
        phone.list.library.save(link("https://a.com/x"), now: at(1))
        let firstTry = phone.bridge.pendingChanges().saves
        #expect(firstTry.count == 1)
        // No confirmation arrived (killed mid-send): still pending.
        #expect(phone.bridge.pendingChanges().saves.count == 1)

        // The first attempt did land; the pad edits after it; then the phone's replay lands.
        zone.records[firstTry[0].recordID.recordName] = firstTry[0]
        pad.fetch(from: zone)
        pad.list.library.setRead(id: FastTabListLibrary.itemID(for: "https://a.com/x"), true, now: at(5))
        pad.send(to: zone)
        phone.send(to: zone) // stale replay clobbers the server copy…
        pad.fetch(from: zone) // …but merging keeps the pad's newer read
        #expect(pad.list.library.liveItems.first?.isRead == true)
        pad.send(to: zone)  // and re-asserts it
        phone.fetch(from: zone)
        #expect(phone.list.library.liveItems.first?.isRead == true)
    }

    @Test func conflictRetryCarriesTheMergeOnTheServerRecord() throws {
        let phone = Device(), pad = Device()
        phone.list.library.save(link("https://a.com/x", title: "Phone"), now: at(3))
        pad.list.library.save(link("https://a.com/x", title: "Pad"), now: at(2))
        pad.list.library.recordProgress(url: "https://a.com/x", progress: 0.4, now: at(2))
        let mine = phone.bridge.pendingChanges().saves[0]
        let server = pad.bridge.pendingChanges().saves[0]
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])

        guard case .retry(let retry) = phone.bridge.outcome(ofFailedSave: mine, error: error) else {
            Issue.record("expected a retry"); return
        }
        #expect(retry === server, "sent on the server's record (its change tag)")
        let merged = try #require(SyncedListItem(from: retry)?.item)
        #expect(merged.title == "Phone" && merged.progress == 0.4)
        #expect(phone.list.library.liveItems.first?.progress == 0.4, "local copy merged too")
    }

    @Test func conflictWithANewerServerCopySettlesWithoutSending() {
        let phone = Device(), pad = Device()
        phone.list.library.save(link("https://a.com/x", title: "Phone"), now: at(1))
        pad.list.library.save(link("https://a.com/x", title: "Pad"), now: at(2))
        let mine = phone.bridge.pendingChanges().saves[0]
        let server = pad.bridge.pendingChanges().saves[0]
        let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        guard case .settled = phone.bridge.outcome(ofFailedSave: mine, error: error) else {
            Issue.record("expected settled"); return
        }
        #expect(phone.list.library.liveItems.first?.title == "Pad")
        #expect(phone.bridge.pendingChanges().saves.isEmpty)
    }

    @Test func accountSwitchKeepsItemsAndReuploadsEverything() {
        let zone = FakeZone(), phone = Device()
        for index in 0..<3 { phone.list.library.save(link("https://a.com/\(index)"), now: at(1)) }
        phone.send(to: zone)
        #expect(phone.bridge.pendingChanges().saves.isEmpty)
        phone.bridge.resetLedger()
        #expect(phone.list.library.itemsByID.count == 3)
        #expect(phone.bridge.pendingChanges().saves.count == 3)
    }

    @Test func otherReaderRecordTypesAreIgnored() {
        let phone = Device()
        let highlight = SyncedReaderHighlight(id: "h", urlKey: "k", payload: Data("{}".utf8))
            .toRecord(zoneID: SyncConstants.readerZoneID)
        phone.bridge.absorb([highlight, CKRecord(recordType: "SomeFutureType",
            recordID: CKRecord.ID(recordName: "li|x", zoneID: SyncConstants.readerZoneID))])
        phone.bridge.absorbDeletions([CKRecord.ID(recordName: "hl|h", zoneID: SyncConstants.readerZoneID)])
        #expect(phone.list.library.itemsByID.isEmpty)
        #expect(!ReaderSyncBridge.handles(SyncedListItem.recordType), "old reader bridge skips list records")
    }
}
