import XCTest
import FastTabSync
@testable import FastTabMobile

/// Read Again on the phone: marking any link (bookmark, card, list item) makes exactly one
/// flagged FastTab List item; Shuffle deals Read Again cards in both modes; Emerging gets a
/// small Read Again lane under the same filters as its other lanes; read counts.
@MainActor
final class ReadAgainTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func makeStore() -> SavedOnIPhoneStore {
        let suiteName = "ReadAgainTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: dir)
        }
        let fileStore = FastTabListFileStore(fileURL: dir.appendingPathComponent("list.json"), defaults: defaults)
        return SavedOnIPhoneStore(fileStore: fileStore, pendingSavesContainerURL: nil, now: { self.start }, writeDebounce: .zero)
    }

    private func makeCounts() -> ReaderReadCounts {
        let suiteName = "ReadAgainCounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return ReaderReadCounts(defaults: defaults)
    }

    // MARK: - Marking

    func testMarkingABookmarkCreatesExactlyOneFlaggedListItem() throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/bm"))
        XCTAssertTrue(store.markReadAgain(url: url.absoluteString, title: "Bookmark"))
        XCTAssertTrue(store.markReadAgain(url: "https://EXAMPLE.com/bm#top", title: "Bookmark"))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.isReadAgain(url))
        XCTAssertEqual(store.readAgainItems.map(\.url), [url.absoluteString])
        XCTAssertFalse(store.markReadAgain(url: "file:///tmp/x", title: "x"))
    }

    func testMarkingAListItemDoesNotDuplicateIt() throws {
        let store = makeStore()
        XCTAssertTrue(store.readLater(url: "https://example.com/a", title: "A"))
        store.markReadAgain(url: "https://example.com/a", title: "A")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items[0].isReadAgain)
    }

    func testRemoveFromReadAgainKeepsTheItemAndTrashHidesTheFlag() throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        store.markReadAgain(url: url.absoluteString, title: "A")
        let id = try XCTUnwrap(store.liveItem(for: url)?.id)

        store.remove(id: id)
        XCTAssertFalse(store.isReadAgain(url), "Trashed items are not in Read Again")
        store.restore(id: id)
        XCTAssertTrue(store.isReadAgain(url), "Restoring brings the flag back")

        store.removeFromReadAgain(url: url)
        XCTAssertFalse(store.isReadAgain(url))
        XCTAssertEqual(store.items.count, 1)
    }

    func testMarkSeedsTheListCountFromThePhonesOwnCount() throws {
        let store = makeStore()
        let counts = makeCounts()
        let url = try XCTUnwrap(URL(string: "https://example.com/bm"))
        counts.increment(url)
        counts.increment(url)
        let state = LinkReadState(saved: store, counts: counts)
        XCTAssertEqual(state.readCount(url), 2)

        XCTAssertEqual(state.toggleReadAgain(url: url, title: "B"), "Added to Read Again")
        XCTAssertEqual(store.liveItem(for: url)?.readCount, 2)
        XCTAssertEqual(state.toggleReadAgain(url: url, title: "B"), "Removed from Read Again")
        XCTAssertFalse(store.isReadAgain(url))
    }

    func testReadCountShowsTheLargerOfLocalAndSynced() throws {
        let store = makeStore()
        let counts = makeCounts()
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        store.readLater(url: url.absoluteString, title: "A")
        store.recordFinishedRead(url: url)
        store.recordFinishedRead(url: url)
        store.recordFinishedRead(url: url)
        counts.increment(url)
        XCTAssertEqual(LinkReadState(saved: store, counts: counts).readCount(url), 3)
    }

    func testLocalCountsEvictTheLeastRecentlyCounted() throws {
        let counts = makeCounts()
        for index in 0...ReaderReadCounts.maxEntries {
            counts.increment(try XCTUnwrap(URL(string: "https://example.com/\(index)")),
                             now: start.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertEqual(counts.count(for: try XCTUnwrap(URL(string: "https://example.com/0"))), 0)
        XCTAssertEqual(counts.count(for: try XCTUnwrap(URL(string: "https://example.com/\(ReaderReadCounts.maxEntries)"))), 1)
    }

    func testEndOfArticleLabelsMatchTheOtherSurfaces() {
        XCTAssertEqual(ReaderEndActions.readAgainLabel(isReadAgain: false), "Read Again")
        XCTAssertEqual(ReaderEndActions.readAgainLabel(isReadAgain: true), "Remove from Read Again")
    }

    // MARK: - Shuffle

    private func link(_ path: String, readAgain: Bool) -> SavedOnIPhoneLink {
        let url = "https://example.com/\(path)"
        return SavedOnIPhoneLink(id: FastTabListLibrary.itemID(for: url), url: url, title: path, savedAt: start,
                                 readAgainAt: readAgain ? start : nil)
    }

    private func bookmarkCard(_ path: String) -> RandomCardItem {
        let bookmark = SyncedBookmarkItem(id: path, title: path, url: "https://example.com/\(path)")
        let source = BookmarkSource(deviceID: "mac", browserName: "Chrome", profileName: "Default")
        return RandomCardItem(id: "bookmark|\(path)", title: path, url: URL(string: bookmark.url)!,
                              source: .bookmark(item: bookmark, source: source))
    }

    func testShuffleDealsReadAgainCardsWithAMacPool() {
        let readAgain = ShuffleDeck.readAgainCards([link("again", readAgain: true), link("plain", readAgain: false)],
                                                   isSkipped: { _ in false })
        XCTAssertEqual(readAgain.map(\.id), ["saved|\(link("again", readAgain: true).id)"])

        let pool = (0..<100).map { bookmarkCard("b\($0)") } + [bookmarkCard("again")]
        let deck = ShuffleDeck.build(pool: pool, readAgain: readAgain, maxSize: 40, shuffle: { $0 })
        XCTAssertEqual(deck.count, 40)
        XCTAssertEqual(deck.filter { $0.url.lastPathComponent == "again" }.count, 1, "The Read Again card replaces the bookmark card")
        XCTAssertTrue(deck.contains { $0.id.hasPrefix("saved|") })
    }

    func testShuffleDealsReadAgainCardsInReaderOnlyModeWithoutDuplicates() {
        let links = [link("again", readAgain: true), link("plain", readAgain: false)]
        let readerOnlyPool = links.map {
            RandomCardItem(id: "saved|\($0.id)", title: $0.url, url: URL(string: $0.url)!, source: .savedLink($0))
        }
        let readAgain = ShuffleDeck.readAgainCards(links, isSkipped: { _ in false })
        let deck = ShuffleDeck.build(pool: readerOnlyPool, readAgain: readAgain, maxSize: 40, shuffle: { $0 })
        XCTAssertEqual(deck.count, 2)
        XCTAssertEqual(Set(deck.map(\.id)).count, 2)
    }

    func testShuffleRespectsSkipsAndCapsReadAgainCards() {
        let links = (0..<30).map { link("again\($0)", readAgain: true) }
        let skippedID = "saved|\(links[0].id)"
        let readAgain = ShuffleDeck.readAgainCards(links, isSkipped: { $0 == skippedID })
        XCTAssertEqual(readAgain.count, 29)
        let deck = ShuffleDeck.build(pool: (0..<100).map { bookmarkCard("b\($0)") }, readAgain: readAgain, maxSize: 40)
        XCTAssertEqual(deck.filter { $0.id.hasPrefix("saved|") }.count, ShuffleDeck.maxReadAgain)
        XCTAssertFalse(deck.contains { $0.id == skippedID })
    }

    // MARK: - Emerging

    private func candidate(_ urlString: String, markedDaysAgo: Double = 1) -> ReadAgainCandidate {
        ReadAgainCandidate(url: URL(string: urlString)!, title: urlString,
                           markedAt: start.addingTimeInterval(-markedDaysAgo * day))
    }

    private func opened(_ urlString: String, daysAgo: Double) -> LastOpenedItem {
        LastOpenedItem(url: urlString, title: urlString, openedAt: start.addingTimeInterval(-daysAgo * day))
    }

    private func lane(
        _ candidates: [ReadAgainCandidate], lastOpened: [LastOpenedItem] = [],
        dismissedHosts: Set<String> = [], dismissedLinkKeys: Set<String> = []
    ) -> [EmergingItem] {
        EmergingContentProvider.readAgainLane(candidates, lastOpened: lastOpened, dismissedHosts: dismissedHosts,
                                              dismissedLinkKeys: dismissedLinkKeys, now: start)
    }

    func testEmergingLanePicksTwoPreferringLinksNotOpenedLately() {
        let items = lane(
            [candidate("https://a.com/1"), candidate("https://b.com/2"), candidate("https://c.com/3")],
            lastOpened: [opened("https://a.com/1", daysAgo: 20), opened("https://c.com/3", daysAgo: 40)]
        )
        XCTAssertEqual(items.map(\.url.absoluteString), ["https://b.com/2", "https://c.com/3"])
        XCTAssertTrue(items.allSatisfy { $0.lane == .readAgain && $0.badgeText == "Read Again" })
    }

    func testEmergingLaneSkipsRecentlyOpenedAndDismissed() {
        let items = lane(
            [candidate("https://a.com/1"), candidate("https://b.com/2"), candidate("https://c.com/3"), candidate("https://d.com/4")],
            lastOpened: [opened("https://a.com/1", daysAgo: 2)],
            dismissedHosts: ["b.com"],
            dismissedLinkKeys: [EmergingURLUtils.dedupeKey(URL(string: "https://c.com/3")!)]
        )
        XCTAssertEqual(items.map(\.url.absoluteString), ["https://d.com/4"])
    }

    func testEmergingLaneCapsLinksPerWebsite() {
        let items = lane([
            candidate("https://a.com/1", markedDaysAgo: 3), candidate("https://a.com/2", markedDaysAgo: 2),
            candidate("https://a.com/3", markedDaysAgo: 1),
        ])
        XCTAssertEqual(items.count, 2)
        let three = EmergingContentProvider.readAgainLane(
            [candidate("https://a.com/1"), candidate("https://a.com/2"), candidate("https://a.com/3"), candidate("https://b.com/1")],
            lastOpened: [], dismissedHosts: [], dismissedLinkKeys: [], now: start, target: 4)
        XCTAssertEqual(three.filter { $0.domain == "a.com" }.count, 2)
        XCTAssertEqual(three.count, 3)
    }
}
