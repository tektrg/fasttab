import Foundation
import Testing
import CommandBarKit
@testable import FastTab

@Suite("Tab Search Repro Tests")
struct TabSearchReproTests {
    let edgeTab = BrowserSearchResult(
        title: "send my youtube tabs to feed — OpenClaw",
        url: "http://127.0.0.1:18789/chat/main/b07ae87c",
        browserName: "Microsoft Edge",
        type: .tab,
        timestamp: Date(timeIntervalSince1970: 1789274445),
        windowIndex: 1,
        tabIndex: 36,
        windowName: "Ext mnt",
        isCurrentFlowActiveTab: false,
        tabID: 484803551
    )

    @Test func edgeTabMatchesVariousQueries() {
        let queries = [
            "openclaw",
            "OpenClaw",
            "feed",
            "youtube",
            "send my youtube",
            "127.0.0.1",
            "127.0.0.1:18789",
            "18789",
            "chat",
            "main",
            "b07ae87c",
            "http://127.0.0.1:18789/chat/main/b07ae87c"
        ]

        for q in queries {
            let words = searchWords(in: q)
            #expect(edgeTab.matches(words: words), "Query '\(q)' should match tab")
        }
    }

    @Test func edgeTabSurvivesDeduplicatingSamePagesWithHistory() {
        let historyEntry = BrowserSearchResult(
            title: "send my youtube tabs to feed — OpenClaw",
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            browserName: "Microsoft Edge",
            type: .history,
            timestamp: Date(timeIntervalSince1970: 1789275000)
        )

        let frecencyLookup: (BrowserSearchResult) -> Double = { _ in 0 }
        let deduped = deduplicatingSamePages([edgeTab, historyEntry], frecencyScore: frecencyLookup)

        #expect(deduped.count == 1)
        #expect(deduped.first?.type == .tab, "Live tab must beat history entry")
        #expect(deduped.first?.id == edgeTab.id)
    }

    @Test func edgeTabSurvivesDeduplicatingWithHistoryReversedOrder() {
        let historyEntry = BrowserSearchResult(
            title: "send my youtube tabs to feed — OpenClaw",
            url: "http://127.0.0.1:18789/chat/main/b07ae87c",
            browserName: "Microsoft Edge",
            type: .history,
            timestamp: Date(timeIntervalSince1970: 1789275000)
        )

        let frecencyLookup: (BrowserSearchResult) -> Double = { _ in 0 }
        let deduped = deduplicatingSamePages([historyEntry, edgeTab], frecencyScore: frecencyLookup)

        #expect(deduped.count == 1)
        #expect(deduped.first?.type == .tab, "Live tab must beat history entry when history comes first")
    }

    @Test func localhostQueriesMatchLocalIPTab() {
        let localhostQueries = [
            "localhost",
            "localhost:18789",
            "http://localhost:18789"
        ]
        for q in localhostQueries {
            let words = searchWords(in: q)
            #expect(edgeTab.matches(words: words), "Query '\(q)' should match 127.0.0.1 tab")
        }
    }

    @Test func localIPQueriesMatchLocalhostTab() {
        let localhostTab = BrowserSearchResult(
            title: "Localhost Web App",
            url: "http://localhost:3000/dashboard",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: Date()
        )
        let queries = [
            "127.0.0.1",
            "127.0.0.1:3000"
        ]
        for q in queries {
            let words = searchWords(in: q)
            #expect(localhostTab.matches(words: words), "Query '\(q)' should match localhost tab")
        }
    }

    @Test func historyPageIdentityPreservesNonDefaultPorts() {
        let page1 = historyPageIdentity(forURL: "http://127.0.0.1:18789/chat")
        let page2 = historyPageIdentity(forURL: "http://127.0.0.1:4711/chat")
        #expect(page1 != page2, "Different ports must produce different page identities")
        #expect(page1 == "127.0.0.1:18789/chat")
        #expect(page2 == "127.0.0.1:4711/chat")

        // Standard ports 80 and 443 should still be omitted
        let httpStandard = historyPageIdentity(forURL: "http://example.com:80/path/")
        let httpsStandard = historyPageIdentity(forURL: "https://example.com:443/path")
        #expect(httpStandard == "example.com/path")
        #expect(httpsStandard == "example.com/path")
    }

    @Test func loopbackZeroIPQueriesMatch() {
        let zeroIPTab = BrowserSearchResult(
            title: "Zero IP Server",
            url: "http://0.0.0.0:8000/api",
            browserName: "Microsoft Edge",
            type: .tab,
            timestamp: Date()
        )
        for q in ["localhost", "127.0.0.1", "0.0.0.0", "localhost:8000", "127.0.0.1:8000"] {
            let words = searchWords(in: q)
            #expect(zeroIPTab.matches(words: words), "Query '\(q)' should match 0.0.0.0 tab")
        }
    }

    @Test func historySearchSQLPredicateMatchesLoopbackEquivalentsInSQLite() async throws {
        let localhostPredicate = historySearchSQLPredicate(query: "localhost", urlColumn: "url", titleColumn: "title")
        #expect(localhostPredicate.contains("127.0.0.1"), "localhost query predicate must include 127.0.0.1 glob")

        let rows = [
            ("OpenClaw Web", "http://127.0.0.1:18789/chat"),
            ("Local Dev App", "http://localhost:3000/app")
        ]

        let localhostMatches = try titlesMatchingInSQLite(query: "localhost", rows: rows)
        #expect(localhostMatches.contains("OpenClaw Web"), "Searching localhost should find 127.0.0.1 history row")
        #expect(localhostMatches.contains("Local Dev App"), "Searching localhost should find localhost history row")

        let ipMatches = try titlesMatchingInSQLite(query: "127.0.0.1", rows: rows)
        #expect(ipMatches.contains("OpenClaw Web"), "Searching 127.0.0.1 should find 127.0.0.1 history row")
        #expect(ipMatches.contains("Local Dev App"), "Searching 127.0.0.1 should find localhost history row")
    }

    @Test func edgeCaseQueriesMatch() {
        // 1. "local", subpaths, trailing slashes, ports
        let edgeCaseQueries = [
            "local",
            "local 18789",
            "localhost:18789/",
            "127.0.0.1:18789/",
            "chat/main",
            "chat/main/b07ae87c",
            "openclaw 18789",
            "openclaw localhost",
            "openclaw local"
        ]
        for q in edgeCaseQueries {
            let words = searchWords(in: q)
            #expect(edgeTab.matches(words: words), "Query '\(q)' should match edgeTab")
        }

        // 2. Complex URLs with query params and anchors
        let complexTab = BrowserSearchResult(
            title: "Local Dashboard — DevApp",
            url: "http://127.0.0.1:8080/app/view?tab=orders&sort=desc#anchor-1",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date()
        )
        for q in ["localhost", "local", "8080", "orders", "anchor", "devapp", "localhost:8080/app"] {
            let words = searchWords(in: q)
            #expect(complexTab.matches(words: words), "Query '\(q)' should match complexTab")
        }
    }
}
