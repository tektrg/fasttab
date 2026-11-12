import Foundation
import Testing
import IndieSearch
@testable import FastTab

/// Gap 6 characterization: moving Fast Tab's search box onto IndieSearch `SearchBoxQuery`
/// must not change what a plain query shows or in which order. The oracle is the pre-change
/// pipeline (`matches(words: searchWords(in:))`, then dedupe + frecency sort), kept here.
@Suite("Search box characterization")
struct SearchBoxCharacterizationTests {
    private static let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private static func r(_ title: String, _ url: String, _ type: BrowserResultType, ago: TimeInterval,
                          browser: String = "Google Chrome", folder: String? = nil) -> BrowserSearchResult {
        BrowserSearchResult(title: title, url: url, browserName: browser, type: type,
                            timestamp: t0.addingTimeInterval(-ago), folderPath: folder)
    }

    static let corpus: [BrowserSearchResult] = [
        r("Realtime e-commerce order | Bi Hub", "https://bi.example.com/orders", .tab, ago: 10),
        r("GitHub · tektrg/fasttab issues", "https://github.com/tektrg/fasttab/issues", .tab, ago: 30),
        r("Issue #42 · tektrg/fasttab", "https://github.com/tektrg/fasttab/issues/42", .history, ago: 300),
        r("Việt Nam house prices", "https://vn-house.example.com/", .bookmark, ago: 0, folder: "Bookmarks Bar / Home"),
        r("OpenClaw chat", "http://127.0.0.1:18789/chat/main", .tab, ago: 60, browser: "Microsoft Edge"),
        r("Localhost dev", "http://localhost:3000/", .history, ago: 900),
        r("GitHub · tektrg/fasttab issues", "https://github.com/tektrg/fasttab/issues", .history, ago: 5),
        r("Docs — Swift Testing", "https://developer.apple.com/documentation/testing", .bookmark, ago: 0, folder: "Dev"),
        r("Pull request 7 · tektrg/indielibkit", "https://github.com/tektrg/indielibkit/pull/7", .tab, ago: 120, browser: "Safari"),
    ]

    static func frecency(_ result: BrowserSearchResult) -> Double {
        result.url.contains("github") ? 5 : (result.url.contains("127.0.0.1") ? 9 : 1)
    }

    static let plainQueries = [
        "", "  ", "git", "github issues", "ISSUES github", "fasttab 42", "viet", "việt nam", "e-commerce",
        "real time", "localhost", "127.0.0.1", "0000", "tektrg.indielibkit", "docs swift", "nothing-here",
        "hub", "/", "a/b", "*",
    ]

    private static func oldPipeline(_ query: String, _ candidates: [BrowserSearchResult]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = searchWords(in: q)
        let matched = q.isEmpty ? candidates : candidates.filter { $0.matches(words: words) }
        return sortBrowserSearchResults(deduplicatingSamePages(matched, frecencyScore: frecency), frecencyScore: frecency).map(\.id)
    }

    private static func newPipeline(_ query: String, _ candidates: [BrowserSearchResult]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchQuery = SearchBoxQuery(q)
        let matched = q.isEmpty ? candidates : candidates.filter { $0.matches(searchQuery) }
        return sortBrowserSearchResults(deduplicatingSamePages(matched, frecencyScore: frecency), frecencyScore: frecency).map(\.id)
    }

    @Test(arguments: plainQueries)
    func plainQueryFiltersAndRanksAsBefore(query: String) {
        #expect(Self.newPipeline(query, Self.corpus) == Self.oldPipeline(query, Self.corpus))
    }

    /// Scopes (`in:Bookmarks`, `in:History`, a source) narrow first, then the box query; same order as before.
    @Test(arguments: [BrowserResultType.tab, .bookmark, .history])
    func scopedPlainQueriesUnchanged(type: BrowserResultType) {
        var filter = ScopeFilter()
        filter.requiredType = type
        let scoped = Self.corpus.filter { filter.matches($0) }
        for query in Self.plainQueries {
            #expect(Self.newPipeline(query, scoped) == Self.oldPipeline(query, scoped), "\(type) '\(query)'")
        }
    }

    @Test func frecencyOrderIsPinned() {
        // Golden order for "github": the frecency-ranked list as it is today.
        let ids = Self.oldPipeline("github", Self.corpus)
        #expect(!ids.isEmpty)
        #expect(Self.newPipeline("github", Self.corpus) == ids)
    }

    @Test func wildcardAndRegexReachTheBox() {
        let titles = { (q: String) in Self.corpus.filter { $0.matches(SearchBoxQuery(q)) }.map(\.title) }
        #expect(titles("github.com/*/issues/*").contains("Issue #42 · tektrg/fasttab"))
        #expect(titles("/issues/\\d+$/") == ["Issue #42 · tektrg/fasttab"])
        #expect(titles("/^pull request/").count == 1)
        #expect(titles("*e-commerce*") == ["Realtime e-commerce order | Bi Hub"])
        #expect(titles("/([/").isEmpty)
    }
}
