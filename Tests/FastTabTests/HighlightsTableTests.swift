import FastTabSync
import Foundation
import IndieComments
import Testing
@testable import FastTabReader

/// A mirror folder seeded like the phone would sync it, then the Highlights views over it.
@MainActor
@Suite("Highlights table (IndieTable views over the reader mirror)")
struct HighlightsTableTests {
    let agent = CommentAuthor(kind: .agent, id: "claude")
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// h1 + h2 on a.com/one (h2 older day), h3 on b.org/two.
    func makeLibrary() -> ReaderLibrary {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hl-table-\(UUID().uuidString)")
        let mirror = ReaderMirror(directory: dir)
        func add(_ id: String, _ text: String, url: String, title: String, start: Int, day: Double) {
            let json: [String: Any] = [
                "id": id, "urlKey": url, "urlString": url, "selectedText": text, "color": "yellow",
                "serializedRange": #"{"text":"\#(text)","start":\#(start),"len":\#(text.utf16.count)}"#,
                "createdAt": 780_000_000 + day * 86_400, "title": title, "tags": [String](),
            ]
            let payload = try! JSONSerialization.data(withJSONObject: json)
            mirror.applyRemote(SyncedReaderHighlight(id: id, urlKey: url, payload: payload))
        }
        add("h1", "alpha idea", url: "https://www.a.com/one", title: "One", start: 0, day: 2)
        add("h2", "beta point", url: "https://www.a.com/one", title: "One", start: 20, day: 0)
        add("h3", "gamma fact", url: "https://b.org/two", title: "Two", start: 5, day: 1)
        return ReaderLibrary(directory: dir, comments: mirror.comments)
    }

    @Test func allIsNewestFirstAndOpenThreadsFollowComments() async throws {
        let library = makeLibrary()
        var entries = await library.entries()
        #expect(try HighlightsTable.run(.all, entries: entries).first?.entries.map(\.id) == ["h1", "h3", "h2"])
        #expect(try HighlightsTable.run(.openThreads, entries: entries).first?.entries.isEmpty == true)

        try await library.comment("worth a post", onHighlight: "h3", by: agent)
        try await library.comment("check source", onHighlight: "h2", by: agent)
        try await library.setResolved(true, onHighlight: "h2", by: agent)
        entries = await library.entries()
        #expect(try HighlightsTable.run(.openThreads, entries: entries).first?.entries.map(\.id) == ["h3"])

        // A reply reopens; the thread is found by anchor (no link on the highlight).
        let reopened = try await library.comment("again", onHighlight: "h2", by: agent)
        #expect(reopened.status == "open")
        #expect(reopened.comments.compactMap(\.text) == ["check source", "again"])
    }

    @Test func byPageAndByDateGroup() async throws {
        let entries = await makeLibrary().entries()
        let byPage = try HighlightsTable.run(.byPage, entries: entries)
        #expect(byPage.map(\.title) == ["a.com · One", "b.org · Two"])
        #expect(byPage.first?.entries.map(\.id) == ["h1", "h2"])

        let byDate = try HighlightsTable.run(.byDate, entries: entries, calendar: calendar)
        #expect(byDate.map { $0.entries.map(\.id) } == [["h1"], ["h3"], ["h2"]])
        #expect(byDate.first?.title?.count == 10)
    }

    @Test func searchCoversQuotesCommentsAndPages() async throws {
        let library = makeLibrary()
        try await library.comment("Đơn hàng note", onHighlight: "h1", by: agent)
        let entries = await library.entries()
        func ids(_ query: String) throws -> [String] {
            try HighlightsTable.run(.all, search: query, entries: entries).flatMap { $0.entries.map(\.id) }
        }
        #expect(try ids("gamma") == ["h3"])
        #expect(try ids("don hang") == ["h1"], "comments, accent-insensitive")
        #expect(try ids("Two") == ["h3"])
        #expect(try HighlightsTable.run(.openThreads, search: "gamma", entries: entries).first?.entries.isEmpty == true)
    }

    @Test func actionsRefuseUnknownHighlightsAndEmptyText() async throws {
        let library = makeLibrary()
        await #expect(throws: ReaderLibrary.Failure.highlightNotFound("nope")) {
            try await library.comment("x", onHighlight: "nope", by: agent)
        }
        await #expect(throws: ReaderLibrary.Failure.emptyComment) {
            try await library.comment("  ", onHighlight: "h1", by: agent)
        }
        await #expect(throws: ReaderLibrary.Failure.noThread("h1")) {
            try await library.setResolved(true, onHighlight: "h1", by: agent)
        }
    }
}

@Suite("Highlight ↔ thread assignment")
struct ReaderHighlightThreadAssignmentTests {
    struct H { let id: String; let link: String?; let range: String; let text: String }

    func thread(_ id: String, from: Int, quote: String) -> CommentThread {
        let opener = CommentEvent(id: id, threadId: id, kind: .threadOpened, prev: nil,
                                  by: CommentAuthor(kind: .agent, id: "a"),
                                  anchor: TextAnchor(from: from, to: from + quote.utf16.count, quote: quote), text: "t")
        return CommentThreadBuilder.threads(docId: "d", events: [opener], text: "")[0]
    }

    func assign(_ highlights: [H], _ threads: [CommentThread]) -> [String: String] {
        ReaderHighlightThreads.assign(highlights, threads: threads, id: \.id, linkedThreadId: \.link,
                                      serializedRange: \.range, selectedText: \.text).mapValues(\.id)
    }

    @Test func aThreadGoesToOneHighlightOnly() {
        let range = #"{"text":"same","start":4,"len":4}"#
        let threads = [thread("t1", from: 4, quote: "same")]
        // Linked elsewhere: the unlinked copy of the passage does not get it.
        #expect(assign([H(id: "a", link: "t1", range: range, text: "same"), H(id: "b", link: nil, range: range, text: "same")],
                       threads) == ["a": "t1"])
        // Two unlinked copies: the first takes it.
        #expect(assign([H(id: "a", link: nil, range: range, text: "same"), H(id: "b", link: nil, range: range, text: "same")],
                       threads) == ["a": "t1"])
    }

    @Test func highlightsWithoutOffsetsNeverMatchByAnchor() {
        #expect(assign([H(id: "a", link: nil, range: #"{"text":"same"}"#, text: "same")],
                       [thread("t1", from: 0, quote: "same")]).isEmpty)
    }
}
