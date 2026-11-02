import Foundation
import Testing
@testable import FastTabSync

/// Read Again (a synced flag on FastTab List items) and the read count, in the shared model:
/// decoding old payloads, mutators, merge, shelf split, unknown-field pass-through.
@Suite("Read Again + read count")
struct ReadAgainTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    let url = "https://example.com/post"
    var id: String { FastTabListLibrary.itemID(for: url) }

    func library(_ links: SavedOnIPhoneLink...) -> FastTabListLibrary {
        var library = FastTabListLibrary()
        for link in links { library.save(link, now: link.savedAt) }
        return library
    }

    // MARK: - Decode / encode

    @Test("A payload from before Read Again decodes unmarked, count 0, nothing unknown")
    func decodesOldPayload() throws {
        let json = #"{"id":"x","url":"https://a.com","savedAt":0,"updatedAt":5,"progress":0.4,"readAt":3}"#
        let link = try JSONDecoder().decode(SavedOnIPhoneLink.self, from: Data(json.utf8))
        #expect(link.readAgainAt == nil)
        #expect(link.readAgainUpdatedAt == nil)
        #expect(!link.isReadAgain)
        #expect(link.readCount == 0)
        #expect(link.readCountUpdatedAt == nil)
        #expect(link.unknownFields.isEmpty)
        #expect(link.progress == 0.4)
    }

    @Test("Read Again and count survive an encode/decode round trip")
    func roundTrip() throws {
        let link = SavedOnIPhoneLink(id: "x", url: url, savedAt: t0, readAgainAt: at(1),
                                     readAgainUpdatedAt: at(1), readCount: 3, readCountUpdatedAt: at(2))
        let back = try JSONDecoder().decode(SavedOnIPhoneLink.self, from: JSONEncoder().encode(link))
        #expect(back == link)
    }

    @Test("Count 0 is not written, so never-reread items keep their old bytes")
    func zeroCountOmitted() throws {
        let data = try JSONEncoder().encode(SavedOnIPhoneLink(id: "x", url: url, savedAt: t0))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("readCount"))
        #expect(!text.contains("readAgain"))
    }

    @Test("A bad value in a new field reads as unset instead of failing the item")
    func badNewFieldTolerated() throws {
        let json = #"{"id":"x","url":"https://a.com","savedAt":0,"readCount":"lots","readAgainAt":"soon"}"#
        let link = try JSONDecoder().decode(SavedOnIPhoneLink.self, from: Data(json.utf8))
        #expect(link.readCount == 0)
        #expect(link.readAgainAt == nil)
    }

    @Test("Fields from a newer build pass through decode/encode untouched")
    func unknownFieldsPreserved() throws {
        let json = #"{"id":"x","url":"https://a.com","savedAt":0,"futureFlagAt":12.5,"futureTags":["a",true,null,{"k":1}]}"#
        let link = try JSONDecoder().decode(SavedOnIPhoneLink.self, from: Data(json.utf8))
        #expect(link.unknownFields["futureFlagAt"] == .number(12.5))
        #expect(link.unknownFields["futureTags"] == .array([.string("a"), .bool(true), .null, .object(["k": .number(1)])]))

        let reencoded = try JSONEncoder().encode(link)
        let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(object["futureFlagAt"] as? Double == 12.5)
        #expect((object["futureTags"] as? [Any])?.count == 4)
        #expect(try JSONDecoder().decode(SavedOnIPhoneLink.self, from: reencoded) == link)
    }

    @Test("Unknown fields survive a mutation and the CloudKit payload")
    func unknownFieldsSurviveMutationAndPayload() throws {
        let json = #"{"id":"x","url":"https://example.com/post","savedAt":1800000000,"futureFlagAt":7}"#
        let incoming = try JSONDecoder().decode(SavedOnIPhoneLink.self, from: Data(json.utf8))
        var library = FastTabListLibrary()
        library.applyRemote(SavedOnIPhoneLink(id: id, url: url, savedAt: t0))
        var remote = incoming
        remote.id = id
        remote.updatedAt = at(1)
        library.applyRemote(remote)
        library.moveToTrash(id: id, now: at(2))
        let item = try #require(library.item(id: id))
        #expect(item.unknownFields["futureFlagAt"] == .number(7))
        let decoded = try JSONDecoder().decode(SavedOnIPhoneLink.self, from: SyncedListItem(item).payload)
        #expect(decoded.unknownFields["futureFlagAt"] == .number(7))
    }

    // MARK: - Mutators

    @Test("Mark then unmark: flag, timestamps and updatedAt move each time")
    func markUnmark() throws {
        var library = library(SavedOnIPhoneLink(url: url, savedAt: t0))
        library.setReadAgain(id: id, true, now: at(10))
        var item = try #require(library.item(id: id))
        #expect(item.readAgainAt == at(10))
        #expect(item.readAgainUpdatedAt == at(10))
        #expect(item.updatedAt == at(10))

        library.setReadAgain(id: id, true, now: at(20))  // already marked: no change
        #expect(library.item(id: id)?.readAgainAt == at(10))

        library.setReadAgain(id: id, false, now: at(30))
        item = try #require(library.item(id: id))
        #expect(item.readAgainAt == nil)
        #expect(item.readAgainUpdatedAt == at(30))
    }

    @Test("markReadAgain adds a missing link once, marked; a second mark adds nothing")
    func markAddsOnce() throws {
        var library = FastTabListLibrary()
        library.markReadAgain(SavedOnIPhoneLink(url: url, title: "Post", savedAt: at(5)), now: at(5))
        library.markReadAgain(SavedOnIPhoneLink(url: "https://EXAMPLE.com/post", title: "Post", savedAt: at(9)), now: at(9))
        #expect(library.liveItems.count == 1)
        let item = try #require(library.item(id: id))
        #expect(item.readAgainAt == at(5))
        #expect(item.title == "Post")
    }

    @Test("markReadAgain on an existing item keeps its place (savedAt) and progress")
    func markExistingInPlace() throws {
        var library = library(SavedOnIPhoneLink(url: url, savedAt: t0))
        library.recordProgress(url: url, progress: 0.5, now: at(1))
        library.markReadAgain(SavedOnIPhoneLink(url: url, savedAt: at(50)), now: at(50))
        let item = try #require(library.item(id: id))
        #expect(item.savedAt == t0)
        #expect(item.progress == 0.5)
        #expect(item.isReadAgain)
    }

    @Test("markReadAgain seeds the count from the device's own count, never lowers it")
    func markSeedsCount() throws {
        var library = FastTabListLibrary()
        library.markReadAgain(SavedOnIPhoneLink(url: url, savedAt: t0, readCount: 2), now: t0)
        #expect(library.item(id: id)?.readCount == 2)
        library.setReadAgain(id: id, false, now: at(1))
        library.markReadAgain(SavedOnIPhoneLink(url: url, savedAt: at(2), readCount: 1), now: at(2))
        #expect(library.item(id: id)?.readCount == 2)
    }

    @Test("Trash keeps the flag (restore brings it back); a trashed link marked again is restored")
    func trashAndRestore() throws {
        var library = library(SavedOnIPhoneLink(url: url, savedAt: t0))
        library.setReadAgain(id: id, true, now: at(1))
        library.moveToTrash(id: id, now: at(2))
        #expect(library.liveItems.isEmpty)
        #expect(library.trashedItems.first?.isReadAgain == true)
        library.restore(id: id, now: at(3))
        #expect(library.liveItems.first?.isReadAgain == true)

        library.setReadAgain(id: id, false, now: at(4))
        library.moveToTrash(id: id, now: at(5))
        library.markReadAgain(SavedOnIPhoneLink(url: url, savedAt: at(6)), now: at(6))
        #expect(library.liveItems.first?.isReadAgain == true)
    }

    @Test("Rereading never clears Read Again")
    func rereadKeepsFlag() throws {
        var library = library(SavedOnIPhoneLink(url: url, savedAt: t0))
        library.setReadAgain(id: id, true, now: at(1))
        library.recordProgress(url: url, progress: 1, now: at(2))
        library.recordFinishedRead(url: url, now: at(2))
        let item = try #require(library.item(id: id))
        #expect(item.isReadAgain)
        #expect(item.readCount == 1)
        #expect(item.readCountUpdatedAt == at(2))
    }

    @Test("recordFinishedRead ignores links not in the list")
    func finishedReadNeedsItem() {
        var library = FastTabListLibrary()
        let counted = library.recordFinishedRead(url: url, now: t0)
        #expect(!counted)
        #expect(library.itemsByID.isEmpty)
    }

    // MARK: - Merge

    func copy(readAgainAt: Date?, updatedAt: Date?, count: Int = 0, countAt: Date? = nil, edited: TimeInterval = 0) -> SavedOnIPhoneLink {
        SavedOnIPhoneLink(id: "x", url: url, savedAt: t0, updatedAt: at(edited),
                          readAgainAt: readAgainAt, readAgainUpdatedAt: updatedAt,
                          readCount: count, readCountUpdatedAt: countAt)
    }

    @Test("Newer mark wins over an older unmarked copy, both argument orders")
    func mergeMarkWins() {
        let marked = copy(readAgainAt: at(10), updatedAt: at(10), edited: 10)
        let plain = copy(readAgainAt: nil, updatedAt: nil, edited: 20)  // newer title edit elsewhere
        #expect(FastTabListMerge.merge(marked, plain).readAgainAt == at(10))
        #expect(FastTabListMerge.merge(plain, marked).readAgainAt == at(10))
    }

    @Test("Newer unmark wins over an older mark, both argument orders")
    func mergeUnmarkWins() {
        let marked = copy(readAgainAt: at(10), updatedAt: at(10), edited: 30)
        let unmarked = copy(readAgainAt: nil, updatedAt: at(20), edited: 20)
        for merged in [FastTabListMerge.merge(marked, unmarked), FastTabListMerge.merge(unmarked, marked)] {
            #expect(merged.readAgainAt == nil)
            #expect(merged.readAgainUpdatedAt == at(20))
        }
    }

    @Test("Read count merges as the larger count, both argument orders")
    func mergeCountMax() {
        let three = copy(readAgainAt: nil, updatedAt: nil, count: 3, countAt: at(5))
        let one = copy(readAgainAt: nil, updatedAt: nil, count: 1, countAt: at(50), edited: 50)
        for merged in [FastTabListMerge.merge(three, one), FastTabListMerge.merge(one, three)] {
            #expect(merged.readCount == 3)
            #expect(merged.readCountUpdatedAt == at(5))
        }
    }

    @Test("Unknown fields merge the same in both orders")
    func mergeUnknownSymmetric() {
        var a = copy(readAgainAt: nil, updatedAt: nil)
        var b = copy(readAgainAt: nil, updatedAt: nil)
        a.unknownFields = ["f": .number(1), "onlyA": .bool(true)]
        b.unknownFields = ["f": .number(2), "onlyB": .string("b")]
        #expect(FastTabListMerge.merge(a, b) == FastTabListMerge.merge(b, a))
        #expect(FastTabListMerge.merge(a, b).unknownFields.count == 3)

        b.updatedAt = at(9)  // b is the newer edit: its value wins
        #expect(FastTabListMerge.merge(a, b).unknownFields["f"] == .number(2))
        #expect(FastTabListMerge.merge(b, a).unknownFields["onlyA"] == .bool(true))
    }

    // MARK: - Read session + text

    /// What each update returns, in order.
    func counts(startingAt start: Double, _ updates: [Double]) -> [Bool] {
        var session = ReadSession(startProgress: start)
        return updates.map { session.record(progress: $0) }
    }

    @Test("Start low then finish counts once; two finishes in one session still once")
    func sessionCountsOnce() {
        #expect(counts(startingAt: 0.1, [0.5, 0.995, 1, 0.2, 1]) == [false, true, false, false, false])
    }

    @Test("Reopening a finished article parked at the end counts nothing")
    func sessionReopenAtEnd() {
        #expect(counts(startingAt: 1, [1]) == [false])
        #expect(counts(startingAt: 0.9, [1]) == [false])
        #expect(counts(startingAt: 0.89, [0.99]) == [true])
    }

    @Test("Row text: progress alone, count alone, both")
    func progressText() {
        #expect(ReadProgressText.line(progress: 0, readCount: 0) == nil)
        #expect(ReadProgressText.line(progress: 0.4, readCount: 0) == "40% read")
        #expect(ReadProgressText.line(progress: 1, readCount: 0) == "Read")
        #expect(ReadProgressText.line(progress: 1, readCount: 3) == "100% · Read 3×")
        #expect(ReadProgressText.line(progress: 0.995, readCount: 1) == "100% · Read 1×")
        #expect(ReadProgressText.line(progress: 0.4, readCount: 2) == "40% · Read 2×")
        #expect(ReadProgressText.line(progress: 0, readCount: 1) == "Read 1×")
        #expect(ReadProgressText.readCount(0) == nil)
        #expect(ReadProgressText.readCount(12) == "Read 12×")
    }

    @Test("Mac command bar hint adds the count")
    func bridgeHintWithCount() {
        #expect(FastTabListBridge.progressHint(for: SavedOnIPhoneLink(url: url, readAt: t0, progress: 1, readCount: 2)) == "Read 2×")
        #expect(FastTabListBridge.progressHint(for: SavedOnIPhoneLink(url: url, progress: 0.3, readCount: 1)) == "30% · Read 1×")
        #expect(FastTabListBridge.progressHint(for: SavedOnIPhoneLink(url: url, readAt: t0, progress: 1)) == "Read")
    }
}

@Suite("Link shelves: Read Again")
struct LinkShelvesReadAgainTests {
    private struct Link {
        let id: String
        let origin: LinkShelves.Origin
        let progress: Double
        var readAgainAt: Date? = nil
    }

    @Test("Read Again items show only under Read Again, newest mark first, whatever their progress")
    func readAgainExclusive() {
        let t = Date(timeIntervalSince1970: 1_000)
        let links = [
            Link(id: "list", origin: .fastTabList, progress: 0.2),
            Link(id: "againFinished", origin: .fastTabList, progress: 1, readAgainAt: t),
            Link(id: "bookmark", origin: .bookmark, progress: 0),
            Link(id: "againBookmark", origin: .bookmark, progress: 0.3, readAgainAt: t.addingTimeInterval(5)),
            Link(id: "read", origin: .bookmark, progress: 1),
        ]
        let split = LinkShelves.split(links, origin: \.origin, progress: \.progress, readAgainAt: \.readAgainAt)
        #expect(split.readAgain.map(\.id) == ["againBookmark", "againFinished"])
        #expect(split.fastTabList.map(\.id) == ["list"])
        #expect(split.bookmarks.map(\.id) == ["bookmark"])
        #expect(split.read.map(\.id) == ["read"])

        let shelf = LinkShelves.unfinished(links, progress: \.progress, isReadAgain: { $0.readAgainAt != nil })
        #expect(shelf.map(\.id) == ["list", "bookmark"])
    }
}
