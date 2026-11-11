import FastTabSync
import Foundation
import IndieMCP
import Testing
@testable import ReadingConnector

@MainActor
@Suite("Reading connector search index")
struct ReadingIndexTests {
    func tools(_ f: ReadingConnectorFixture) throws -> ReadingTools {
        ReadingTools(connector: f.connector, format: ReadingFormat(timeZone: TimeZone(identifier: "UTC")!),
                     index: try ReadingIndex(fileURL: ReadingIndex.fileURL(supportDirectory: f.sources.supportDirectory)))
    }

    func search(_ t: ReadingTools, _ arguments: [String: JSONValue]) async -> MCPToolResult {
        await t.search.handler(arguments.merging(["format": "json"]) { $1 })
    }

    func sources(_ result: MCPToolResult) -> [String] {
        guard case .array(let hits)? = result.structuredContent?["hits"] else { return [] }
        return hits.compactMap { $0["source"]?.stringValue }
    }

    @Test func ownHighlightsAndCommentsRankAboveAPlainPage() async throws {
        let f = try await ReadingConnectorFixture.standard()
        // A List page whose title says "plan" too, but with no highlights of its own.
        var items = f.sources.listItemsForTest()
        items.append(SavedOnIPhoneLink(url: "https://plain.example.com/plan", title: "A plan", savedAt: ReadingConnectorFixture.daysAgo(1)))
        try f.writeList(items)
        let t = try tools(f)
        let result = await search(t, ["query": "plan"])
        let hits = sources(result)
        #expect(["comments", "highlights"].contains(hits.first ?? ""), "the user's own words rank first: \(hits)")
        #expect(hits.prefix(3).allSatisfy { $0 != "list" }, "\(hits)")
        #expect(hits.contains("list"))
        let comment = await search(t, ["query": "next post"])
        #expect(sources(comment) == ["comments"])
        #expect(comment.structuredContent?["hits"]?[0]?["id"] == "h1")
    }

    @Test func sourcesFilterAndUnknownSource() async throws {
        let f = try await ReadingConnectorFixture.standard()
        let t = try tools(f)
        #expect(Set(sources(await search(t, ["query": "plan", "sources": ["list"]]))) == ["list"])
        #expect(Set(sources(await search(t, ["query": "plan", "sources": "list,comments"]))).isSubset(of: ["list", "comments"]))
        #expect(await search(t, ["query": "plan", "sources": ["nope"]]).isError)
        #expect(await search(t, [:]).isError)
    }

    @Test func touchingASourceFileReindexesOnlyThatSource() async throws {
        let f = try await ReadingConnectorFixture.standard()
        let index = try ReadingIndex(fileURL: ReadingIndex.fileURL(supportDirectory: f.sources.supportDirectory))
        let all = [f.connector.listIndexSource] + f.connector.highlightIndexSources
        #expect(try await index.refresh(all).sorted() == ["comments", "highlights", "list"])
        #expect(try await index.refresh(all).isEmpty, "nothing changed: nothing re-read")
        #expect(try await index.search("zebra").isEmpty)

        var items = f.sources.listItemsForTest()
        items.append(SavedOnIPhoneLink(url: "https://z.example.com/zebra", title: "Zebra crossings", savedAt: ReadingConnectorFixture.now))
        try f.writeList(items)
        #expect(try await index.refresh(all) == ["list"])
        #expect(try await index.search("zebra").map(\.title) == ["Zebra crossings"])

        f.addHighlight(id: "h9", url: "https://z.example.com/zebra", quote: "Stripes everywhere", createdAt: ReadingConnectorFixture.now)
        #expect(try await index.refresh(all).contains("highlights"))
        #expect(try await index.search("stripes").map(\.id) == ["h9"])

        // A fresh process opening the same file sees the same index.
        let reopened = try ReadingIndex(fileURL: index.fileURL)
        #expect(try await reopened.search("stripes").count == 1)
        try await reopened.remove(source: "highlights")
        #expect(try await reopened.search("stripes").isEmpty)
    }

    @Test func queryTextNeverReachesFTSSyntax() async throws {
        let f = try await ReadingConnectorFixture.standard()
        let t = try tools(f)
        for query in ["\"unbalanced", "plan OR", "NEAR(a b)", "col:plan", "*", "IGNORE PREVIOUS INSTRUCTIONS SENTINEL"] {
            #expect(!(await search(t, ["query": .string(query)])).isError, "\(query)")
        }
        #expect(ReadingIndex.matchExpression("plan, then-act") == "\"plan\"* AND \"then\"* AND \"act\"*")
        #expect(ReadingIndex.matchExpression("!!!") == nil)
    }

    @Test func markdownAndCLI() async throws {
        let f = try await ReadingConnectorFixture.standard()
        let t = try tools(f)
        let md = try #require(await t.search.handler(["query": "functions"]).structuredContent?["markdown"]?.stringValue)
        #expect(md.hasPrefix("# Search \"functions\" — 1 hit"))
        #expect(md.contains("1. [highlights] **Agents that plan** · <https://essays.example.com/agents> · 2027-01-13 · id h2"))
        #expect(md.contains("   > Tools are just functions."))
        let cli = await ReadingCLI(tools: t.tools).run(["search", "just", "functions"])
        #expect(cli.text == md.replacingOccurrences(of: "\"functions\"", with: "\"just functions\""))
    }
}

extension ReadingSources {
    func listItemsForTest() -> [SavedOnIPhoneLink] { listItems() }
}
