import Testing
import Foundation
@testable import FastTabSync

/// The "View all" screen's rule: 99-100% read leaves every list and lands in Read only.
@Suite("Link shelves")
struct LinkShelvesTests {
    private struct Link: Equatable {
        let id: String
        let origin: LinkShelves.Origin
        let progress: Double
        var readAt: Date? = nil

        static func == (l: Link, r: Link) -> Bool { l.id == r.id }
    }

    private func split(_ links: [Link]) -> LinkShelves.Split<Link> {
        LinkShelves.split(links, origin: \.origin, progress: \.progress, finishedAt: \.readAt)
    }

    private func ids(_ links: [Link]) -> [String] { links.map(\.id) }

    @Test("99% and 100% are finished; 98% and unread are not")
    func finishLine() {
        #expect(LinkShelves.isFinished(progress: 1.0))
        #expect(LinkShelves.isFinished(progress: 0.99))
        #expect(!LinkShelves.isFinished(progress: 0.98))
        #expect(!LinkShelves.isFinished(progress: 0))
    }

    @Test("Finished links go to Read only, from either origin")
    func finishedGoToRead() {
        let result = split([
            Link(id: "a", origin: .fastTabList, progress: 1.0),
            Link(id: "b", origin: .bookmark, progress: 0.99),
        ])
        #expect(ids(result.read) == ["a", "b"])
        #expect(result.fastTabList.isEmpty)
        #expect(result.bookmarks.isEmpty)
    }

    @Test("98% and never-opened links stay in their own list")
    func unfinishedStay() {
        let result = split([
            Link(id: "list98", origin: .fastTabList, progress: 0.98),
            Link(id: "bm0", origin: .bookmark, progress: 0),
            Link(id: "list0", origin: .fastTabList, progress: 0),
        ])
        #expect(ids(result.fastTabList) == ["list98", "list0"])
        #expect(ids(result.bookmarks) == ["bm0"])
        #expect(result.read.isEmpty)
    }

    @Test("Every link lands in exactly one tab")
    func partitionIsExhaustiveAndDisjoint() {
        let links = [
            Link(id: "1", origin: .fastTabList, progress: 0),
            Link(id: "2", origin: .bookmark, progress: 0.5),
            Link(id: "3", origin: .fastTabList, progress: 1),
            Link(id: "4", origin: .bookmark, progress: 0.995),
            Link(id: "5", origin: .bookmark, progress: 0.98),
        ]
        let result = split(links)
        let all = ids(result.fastTabList) + ids(result.bookmarks) + ids(result.read)
        #expect(all.sorted() == ["1", "2", "3", "4", "5"])
    }

    @Test("The shelf drops finished links and keeps order")
    func shelfHidesFinished() {
        let links = [
            Link(id: "x", origin: .bookmark, progress: 0.2),
            Link(id: "y", origin: .fastTabList, progress: 1),
            Link(id: "z", origin: .fastTabList, progress: 0.98),
        ]
        #expect(ids(LinkShelves.unfinished(links, progress: \.progress)) == ["x", "z"])
    }

    @Test("Read is most recently read first; undated links follow, input order kept")
    func readOrdering() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let result = split([
            Link(id: "undated1", origin: .bookmark, progress: 1),
            Link(id: "old", origin: .fastTabList, progress: 1, readAt: old),
            Link(id: "undated2", origin: .fastTabList, progress: 1),
            Link(id: "new", origin: .bookmark, progress: 1, readAt: new),
        ])
        #expect(ids(result.read) == ["new", "old", "undated1", "undated2"])
    }

    @Test("Input order is kept inside the unfinished lists")
    func orderKept() {
        let result = split([
            Link(id: "n1", origin: .bookmark, progress: 0),
            Link(id: "n2", origin: .bookmark, progress: 0.4),
            Link(id: "n3", origin: .bookmark, progress: 0.1),
        ])
        #expect(ids(result.bookmarks) == ["n1", "n2", "n3"])
    }
}
