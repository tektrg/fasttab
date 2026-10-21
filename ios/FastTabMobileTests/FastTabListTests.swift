import XCTest
import FastTabSync
@testable import FastTabMobile

/// FastTab List (read-later list): migration off UserDefaults, dedupe by canonical
/// URL, Trash + 30-day purge, re-save restores, reader progress / read state.
@MainActor
final class FastTabListTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeFileStore() -> FastTabListFileStore {
        let suiteName = "FastTabListTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
        return FastTabListFileStore(fileURL: dir.appendingPathComponent("list.json"), defaults: defaults)
    }

    private func makeStore(fileStore: FastTabListFileStore? = nil, clock: @escaping () -> Date) -> SavedOnIPhoneStore {
        SavedOnIPhoneStore(
            fileStore: fileStore ?? makeFileStore(),
            pendingSavesContainerURL: nil,
            now: clock,
            writeDebounce: .zero
        )
    }

    // MARK: - Migration

    func testMigratesUserDefaultsSavesOnceKeepingDatesAndRemovesOldKey() throws {
        let fileStore = makeFileStore()
        let savedAt = start.addingTimeInterval(-3 * day)
        let legacy = [SavedOnIPhoneLink(id: "old-uuid", url: "https://example.com/a", title: "A", savedAt: savedAt)]
        fileStore.defaults.set(try JSONEncoder().encode(legacy), forKey: FastTabListFileStore.legacyDefaultsKey)

        let store = makeStore(fileStore: fileStore) { self.start }

        XCTAssertEqual(store.items.map(\.url), ["https://example.com/a"])
        XCTAssertEqual(store.items.first?.title, "A")
        XCTAssertEqual(store.items.first?.savedAt, savedAt)
        XCTAssertNil(fileStore.defaults.data(forKey: FastTabListFileStore.legacyDefaultsKey))
        XCTAssertTrue(fileStore.defaults.bool(forKey: FastTabListFileStore.migrationDoneKey))
        XCTAssertEqual(fileStore.load().count, 1, "migrated items were written to the file")

        // A stale key reappearing later is ignored: migration runs once.
        fileStore.defaults.set(try JSONEncoder().encode(legacy + [SavedOnIPhoneLink(url: "https://example.com/b")]),
                               forKey: FastTabListFileStore.legacyDefaultsKey)
        XCTAssertEqual(fileStore.load().count, 1)
    }

    func testDecodesOldRecordWithoutPhaseOneFields() throws {
        let json = #"{"id":"x","url":"https://example.com","savedAt":0}"#
        let link = try JSONDecoder().decode(SavedOnIPhoneLink.self, from: Data(json.utf8))
        XCTAssertNil(link.deletedAt)
        XCTAssertEqual(link.progress, 0)
        XCTAssertEqual(link.updatedAt, link.savedAt)
    }

    // MARK: - Dedupe

    func testSameLinkWithTrackingAndFragmentIsOneItem() {
        let store = makeStore { self.start }
        store.add([SavedOnIPhoneLink(url: "https://Example.com/post?b=2&a=1", title: "Post")])
        store.add([SavedOnIPhoneLink(url: "https://example.com/post?a=1&b=2&utm_source=x#top")])

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.title, "Post", "an untitled re-save keeps the title")
        XCTAssertEqual(
            FastTabListLibrary.itemID(for: "https://example.com/post?a=1&b=2"),
            FastTabListLibrary.itemID(for: "https://EXAMPLE.com/post?b=2&a=1&fbclid=z")
        )
    }

    // MARK: - Trash

    func testDeleteMovesToTrashAndResaveRestores() {
        var now = start
        let store = makeStore { now }
        store.add([SavedOnIPhoneLink(url: "https://example.com/a")])
        let id = store.items[0].id

        store.remove(id: id)
        XCTAssertTrue(store.items.isEmpty, "trashed items are hidden from the list")
        XCTAssertEqual(store.trashedItems.map(\.id), [id])

        now = start.addingTimeInterval(day)
        store.add([SavedOnIPhoneLink(url: "https://example.com/a", savedAt: now)])
        XCTAssertEqual(store.items.map(\.id), [id])
        XCTAssertTrue(store.trashedItems.isEmpty)
    }

    func testRestoreDeleteNowAndEmptyTrash() {
        let store = makeStore { self.start }
        store.add(["a", "b", "c"].map { SavedOnIPhoneLink(url: "https://example.com/\($0)") })
        let ids = store.items.map(\.id)
        ids.forEach(store.remove(id:))

        store.restore(id: ids[0])
        store.deleteNow(id: ids[1])
        XCTAssertEqual(store.items.map(\.id), [ids[0]])
        XCTAssertEqual(store.trashedItems.map(\.id), [ids[2]])

        store.emptyTrash()
        XCTAssertTrue(store.trashedItems.isEmpty)
        XCTAssertEqual(store.items.count, 1)
    }

    func testTrashPurgedAfterThirtyDays() {
        var library = FastTabListLibrary()
        library.save(SavedOnIPhoneLink(url: "https://example.com/old"), now: start)
        library.save(SavedOnIPhoneLink(url: "https://example.com/new"), now: start)
        let oldID = FastTabListLibrary.itemID(for: "https://example.com/old")
        let newID = FastTabListLibrary.itemID(for: "https://example.com/new")
        library.moveToTrash(id: oldID, now: start)
        library.moveToTrash(id: newID, now: start.addingTimeInterval(10 * day))

        XCTAssertFalse(library.purgeExpiredTrash(now: start.addingTimeInterval(29 * day)))
        XCTAssertTrue(library.purgeExpiredTrash(now: start.addingTimeInterval(30 * day + 1)))
        XCTAssertEqual(library.trashedItems.map(\.id), [newID])
    }

    func testStorePurgesOnLaunch() {
        let fileStore = makeFileStore()
        var now = start
        let store = makeStore(fileStore: fileStore) { now }
        store.add([SavedOnIPhoneLink(url: "https://example.com/a")])
        store.remove(id: store.items[0].id)
        store.flushPendingWrite()

        now = start.addingTimeInterval(31 * day)
        let relaunched = makeStore(fileStore: fileStore) { now }
        XCTAssertTrue(relaunched.trashedItems.isEmpty)
    }

    // MARK: - Progress

    func testProgressMarksReadAtNinetyPercentAndIgnoresUnlistedURLs() {
        var now = start
        let store = makeStore { now }
        store.add([SavedOnIPhoneLink(url: "https://example.com/a")])

        store.recordProgress(url: URL(string: "https://example.com/a#section")!, progress: 0.5)
        XCTAssertEqual(store.items[0].progress, 0.5)
        XCTAssertEqual(store.items[0].progressUpdatedAt, start)
        XCTAssertNil(store.items[0].readAt)

        now = start.addingTimeInterval(60)
        store.recordProgress(url: URL(string: "https://example.com/a")!, progress: 0.92)
        XCTAssertEqual(store.items[0].readAt, now)

        store.recordProgress(url: URL(string: "https://example.com/a")!, progress: 0.1)
        XCTAssertNotNil(store.items[0].readAt, "scrolling back up doesn't un-read")

        store.recordProgress(url: URL(string: "https://other.com/x")!, progress: 1)
        XCTAssertEqual(store.items.count, 1)
    }

    func testExplicitReadToggle() {
        let store = makeStore { self.start }
        store.add([SavedOnIPhoneLink(url: "https://example.com/a")])
        let id = store.items[0].id
        store.setRead(id: id, true)
        XCTAssertTrue(store.items[0].isRead)
        store.setRead(id: id, false)
        XCTAssertFalse(store.items[0].isRead)
    }

    // MARK: - Sync store (FastTabListSyncStore)

    func testLocalEditsAnnounceThemselvesAndRemoteOnesDoNot() {
        let store = makeStore { self.start }
        var announcements = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .fastTabListDidChangeLocally, object: nil, queue: nil) { _ in announcements += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.add([SavedOnIPhoneLink(url: "https://example.com/a")])
        XCTAssertEqual(announcements, 1)

        var remote = store.items[0]
        remote.title = "From iPad"
        remote.updatedAt = start.addingTimeInterval(60)
        _ = store.applyRemoteListItem(remote)
        XCTAssertEqual(store.items.first?.title, "From iPad")
        store.removeRemoteListItem(id: remote.id)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(announcements, 1, "remote changes never echo back as local edits")
    }

    func testRemoteItemPersistsAcrossRelaunch() {
        let fileStore = makeFileStore()
        let store = makeStore(fileStore: fileStore) { self.start }
        let id = FastTabListLibrary.itemID(for: "https://example.com/r")
        _ = store.applyRemoteListItem(SavedOnIPhoneLink(id: id, url: "https://example.com/r", savedAt: start))
        store.flushPendingWrite()
        XCTAssertEqual(makeStore(fileStore: fileStore) { self.start }.items.map(\.id), [id])
    }
}
