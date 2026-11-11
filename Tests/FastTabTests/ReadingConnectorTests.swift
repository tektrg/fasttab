import FastTabSync
import Foundation
import Testing
@testable import ReadingConnector

@MainActor
@Suite("Reading connector engine (List + phone activity + highlights)")
struct ReadingConnectorTests {
    @Test func readingListJoinsListAndPhoneActivityAndSkipsTrash() async throws {
        let f = try await ReadingConnectorFixture.standard()
        let items = f.connector.readingList()
        #expect(items.map(\.displayTitle) == [
            "Halfway there", "Read on the phone", "Agents that plan", "Saved for later", "Old read",
        ])
        let halfway = try #require(items.first)
        #expect(halfway.progress == 0.6, "the fresher phone reading wins")
        #expect(halfway.inList)
        let phoneOnly = try #require(items.first { $0.url == "https://phone.example.com/only" })
        #expect(!phoneOnly.inList)
        #expect(phoneOnly.status == .read)
        #expect(!items.contains { $0.title == "Trashed" })
    }

    @Test func statusAndSinceFilters() async throws {
        let f = try await ReadingConnectorFixture.standard()
        let c = f.connector
        #expect(c.readingList(status: .read).map(\.displayTitle) == ["Read on the phone", "Agents that plan", "Old read"])
        #expect(c.readingList(status: .reading).map(\.displayTitle) == ["Halfway there"])
        #expect(c.readingList(status: .unread).map(\.displayTitle) == ["Saved for later"])
        #expect(c.readingList(status: .readAgain).map(\.displayTitle) == ["Old read"])
        #expect(c.readingList(status: .read, since: ReadingConnectorFixture.daysAgo(7)).count == 2)
        #expect(c.readingList(limit: 2).count == 2)
        let agents = try #require(c.item(url: "https://essays.example.com/agents?utm_source=x"))
        #expect(agents.readCount == 2)
    }

    @Test func highlightsFilterByDatePageAndTopic() async throws {
        let f = try await ReadingConnectorFixture.standard()
        let c = f.connector
        #expect(await c.highlights().map(\.id) == ["h2", "h1", "h3"])
        #expect(await c.highlights(since: ReadingConnectorFixture.daysAgo(7)).map(\.id) == ["h2", "h1"])
        #expect(await c.highlights(url: "https://old.example.com/ancient#frag").map(\.id) == ["h3"])
        #expect(await c.highlights(topic: "next POST").map(\.id) == ["h1"], "topic matches comments too")
        #expect(await c.highlights(topic: "functions").map(\.id) == ["h2"])
        #expect(await c.highlights(topic: "nothing-like-this").isEmpty)
    }

    @Test func articleHasReadingStateAndHighlightsInReadingOrder() async throws {
        let f = try await ReadingConnectorFixture.standard()
        let detail = await f.connector.article(url: "https://essays.example.com/agents")
        #expect(detail.item?.readCount == 2)
        #expect(detail.highlights.map(\.id) == ["h1", "h2"])
        #expect(detail.highlights.first?.comments.compactMap(\.text) == ["This is the core of my next post."])
        let unknown = await f.connector.article(url: "https://nowhere.example.com/")
        #expect(unknown.item == nil && unknown.highlights.isEmpty)
    }

    @Test func emptySupportFolderIsEmptyNotAnError() async throws {
        let f = try ReadingConnectorFixture()
        #expect(f.connector.readingList().isEmpty)
        #expect(await f.connector.highlights().isEmpty)
    }
}
