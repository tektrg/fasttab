import AppKit
import Foundation
import Testing
@testable import FastTab
@testable import FastTabSync

/// The Mac reader window's pure parts: routing, progress → FastTab List, the page it builds,
/// the extraction result it accepts, and its article cache. No web views.
@MainActor
@Suite("Mac reader window")
struct MacReaderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let articleURL = "https://example.com/post?utm_source=x"

    private func makeStore() -> FastTabListStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "MacReaderTests.\(UUID().uuidString)")!
        return FastTabListStore(fileStore: FastTabListFileStore(fileURL: dir.appendingPathComponent("list.json"),
                                                                 defaults: defaults),
                                now: { self.now })
    }

    // MARK: Routing

    @Test func enterOpensReaderAndOptionEnterOpensBrowser() {
        #expect(FastTabListOpenRoute.forModifiers([]) == .reader)
        #expect(FastTabListOpenRoute.forModifiers([.shift]) == .reader)
        #expect(FastTabListOpenRoute.forModifiers([.option]) == .browser)
    }

    @Test func sameArticleFocusesItsWindowOtherArticleOpensNew() {
        let id = FastTabListLibrary.itemID(for: articleURL)
        // Tracking params don't make a second window for the same article.
        #expect(MacReaderWindowRoute.decide(forURL: "https://example.com/post", openItemIDs: [id])
                == .focusExisting(itemID: id))
        let other = FastTabListLibrary.itemID(for: "https://example.com/other")
        #expect(MacReaderWindowRoute.decide(forURL: "https://example.com/other", openItemIDs: [id])
                == .openNew(itemID: other))
    }

    // MARK: Progress

    @Test func readerProgressSyncsWithTimestampAndMarksReadAtNinetyPercent() {
        let store = makeStore()
        store.readLater(url: articleURL, title: "Post")
        let id = FastTabListLibrary.itemID(for: articleURL)

        store.recordReaderProgress(url: articleURL, progress: 0.4)
        #expect(store.item(id: id)?.progress == 0.4)
        #expect(store.item(id: id)?.progressUpdatedAt == now)
        #expect(store.item(id: id)?.readAt == nil)

        store.recordReaderProgress(url: articleURL, progress: 0.92)
        #expect(store.item(id: id)?.readAt == now)
        #expect(store.item(id: id)?.readStateUpdatedAt == now)

        // Scrolling back up keeps it read.
        store.recordReaderProgress(url: articleURL, progress: 0.1)
        #expect(store.item(id: id)?.isRead == true)
    }

    @Test func readerProgressPostsALocalChangeForSync() async {
        let store = makeStore()
        store.readLater(url: articleURL, title: "Post")
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .fastTabListDidChangeLocally, object: nil, queue: nil) { _ in
            posted += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.recordReaderProgress(url: articleURL, progress: 0.5)
        store.recordReaderProgress(url: "https://not-in-the-list.example", progress: 0.5)
        #expect(posted == 1)
    }

    @Test func progressSinkBatchesUntilFlushAndCommitsImmediateOnes() {
        var commits: [Double] = []
        let sink = MacReaderProgressSink(delay: .seconds(3600)) { commits.append($0) }
        sink.receive(progress: 0.2, immediate: false)
        sink.receive(progress: 0.3, immediate: false)
        #expect(commits.isEmpty)
        sink.receive(progress: 0.35, immediate: true)
        #expect(commits == [0.35])
        sink.receive(progress: 0.5, immediate: false)
        sink.stop()
        #expect(commits == [0.35, 0.5])
        sink.flush()
        #expect(commits == [0.35, 0.5])
    }

    @Test func progressSinkWritesAfterTheDelay() async throws {
        var commits: [Double] = []
        let sink = MacReaderProgressSink(delay: .milliseconds(20)) { commits.append($0) }
        sink.receive(progress: 0.6, immediate: false)
        // Bounded poll, not a fixed sleep: a loaded parallel run can starve the timer.
        for _ in 0..<500 where commits.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(commits == [0.6])
    }

    // MARK: Page

    @Test func pageInjectsArticleProgressAndHighlightsWithoutScriptBreakout() throws {
        let article = MacReaderArticle(title: "T", byline: "B", siteName: "S",
                                       content: "<p>x</p></script><script>$(echo INJECTED)</script>",
                                       url: URL(string: articleURL)!, extractedAt: now)
        let highlight = MacReaderPage.Highlight(id: "h1", range: "{\"start\":1,\"len\":2}", color: "rgba(1,1,1,1)")
        let html = MacReaderPage.html(template: "<head><!-- BOOTSTRAP --></head>", article: article,
                                      initialProgress: 0.42, highlights: [highlight])
        #expect(!html.contains("<!-- BOOTSTRAP -->"))
        #expect(html.contains("\"initialProgress\":0.42"))
        #expect(html.contains("\"id\":\"h1\""))
        // Only the bootstrap's own closing tag; the article's `</script>` is escaped.
        #expect(html.components(separatedBy: "</script>").count == 2)
    }

    @Test func highlightsAreMatchedByCanonicalURLAndColoured() throws {
        func synced(_ id: String, url: String, color: String) throws -> SyncedReaderHighlight {
            let key = URL(string: url)!.readerCanonicalKey
            let json: [String: Any] = ["id": id, "urlKey": key, "selectedText": "x", "color": color,
                                       "serializedRange": "{}", "createdAt": 0, "urlString": url]
            return SyncedReaderHighlight(id: id, urlKey: key, payload: try JSONSerialization.data(withJSONObject: json))
        }
        let all = [try synced("a", url: "https://example.com/post", color: "green"),
                   try synced("b", url: "https://example.com/other", color: "yellow")]
        let found = MacReaderPage.highlights(forURL: articleURL, in: all)
        #expect(found.map(\.id) == ["a"])
        #expect(found.first?.color == "rgba(92, 222, 138, 0.40)")
    }

    // MARK: Extraction result + cache

    @Test func extractionResultNeedsContentAndFallsBackToPageTitleAndHost() {
        let url = URL(string: "https://example.com/a")!
        #expect(MacReaderExtractionScript.article(from: nil, url: url, pageTitle: nil) == nil)
        #expect(MacReaderExtractionScript.article(from: ["content": "  "], url: url, pageTitle: nil) == nil)
        #expect(MacReaderExtractionScript.article(from: ["error": "boom"], url: url, pageTitle: nil) == nil)
        let article = MacReaderExtractionScript.article(from: ["content": "<p>hi</p>", "title": ""], url: url,
                                                        pageTitle: "Page", now: now)
        #expect(article?.title == "Page")
        #expect(article?.siteName == "example.com")
    }

    @Test func cacheRoundTripsByCanonicalURLAndSkipsEmptyArticles() {
        let cache = MacReaderArticleCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        let article = MacReaderArticle(title: "T", byline: "", siteName: "", content: "<p>x</p>",
                                       url: URL(string: articleURL)!, extractedAt: now)
        cache.store(article, forURL: articleURL)
        #expect(cache.article(forURL: "https://example.com/post") == article)
        let empty = MacReaderArticle(title: "E", byline: "", siteName: "", content: " ",
                                     url: URL(string: "https://example.com/e")!, extractedAt: now)
        cache.store(empty, forURL: "https://example.com/e")
        #expect(cache.article(forURL: "https://example.com/e") == nil)
    }
}
