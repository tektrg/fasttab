import XCTest
@testable import FastTabMobile

/// Reader preloading: cache hit/miss, silent failure, cancellation, and the promise
/// that preparing an article never touches Last Opened.
@MainActor
final class ReaderPreloaderTests: XCTestCase {

    private final class WarmerSpy: ReaderWebViewWarming {
        var warmedURLs: [URL] = []
        var releaseCount = 0
        func warm(with article: ReaderArticle) { warmedURLs.append(article.url) }
        func release() { releaseCount += 1 }
    }

    private struct FetchFailure: Error {}

    private let cache = ReaderArticleCache()
    private let warmer = WarmerSpy()
    private var fetchedURLs: [URL] = []
    private var testURLs: [URL] = []

    override func tearDown() {
        testURLs.forEach { cache.remove(for: $0) }
        cache.remove(for: ReaderSampleArticle.url)
        testURLs = []
        super.tearDown()
    }

    private func makeURL() -> URL {
        let url = URL(string: "https://preload-test.example/\(UUID().uuidString)")!
        testURLs.append(url)
        return url
    }

    private func article(_ url: URL) -> ReaderArticle {
        ReaderArticle(title: "Fetched", content: "<p>Body</p>", url: url)
    }

    private func makePreloader(fetch: @escaping (URL) async throws -> ReaderArticle) -> ReaderPreloader {
        ReaderPreloader(cache: cache, extract: { [unowned self] url in
            self.fetchedURLs.append(url)
            return try await fetch(url)
        }, warmer: warmer)
    }

    private func waitUntil(_ preloader: ReaderPreloader, _ wanted: ReaderPreloader.Status) async {
        for _ in 0..<200 where preloader.status != wanted {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Cache hit / miss

    func testMissExtractsCachesAndWarms() async {
        let url = makeURL()
        let preloader = makePreloader { self.article($0) }
        preloader.preload(url: url)
        XCTAssertEqual(preloader.status(for: url), .preparing)
        await waitUntil(preloader, .ready)
        XCTAssertEqual(preloader.status(for: url), .ready)
        XCTAssertEqual(cache.article(for: url)?.title, "Fetched")
        XCTAssertEqual(warmer.warmedURLs, [url])
    }

    func testCacheHitSkipsNetworkAndIsReadyImmediately() {
        let url = makeURL()
        cache.save(article(url))
        let preloader = makePreloader { _ in throw FetchFailure() }
        preloader.preload(url: url)
        XCTAssertEqual(preloader.status, .ready)
        XCTAssertTrue(fetchedURLs.isEmpty)
        XCTAssertEqual(warmer.warmedURLs, [url])
    }

    func testRepeatCallForSameURLDoesNotRefetch() async {
        let url = makeURL()
        let preloader = makePreloader { self.article($0) }
        preloader.preload(url: url)
        preloader.preload(url: url)
        await waitUntil(preloader, .ready)
        preloader.preload(url: url)
        XCTAssertEqual(fetchedURLs, [url])
    }

    // MARK: - Failure

    func testFailureIsSilentAndLeavesCacheEmpty() async {
        let url = makeURL()
        let preloader = makePreloader { _ in throw FetchFailure() }
        preloader.preload(url: url)
        await waitUntil(preloader, .failed)
        XCTAssertEqual(preloader.status(for: url), .failed)
        XCTAssertNil(cache.article(for: url))
        XCTAssertTrue(warmer.warmedURLs.isEmpty)
    }

    func testFailedURLIsNotRetriedByRepeatCalls() async {
        let url = makeURL()
        let preloader = makePreloader { _ in throw FetchFailure() }
        preloader.preload(url: url)
        await waitUntil(preloader, .failed)
        preloader.preload(url: url)
        XCTAssertEqual(preloader.status, .failed)
        XCTAssertEqual(fetchedURLs, [url], "tab syncs must not re-run a failing extraction")
    }

    func testCacheHitMatchesTrackingAndFragmentVariants() {
        let url = makeURL()
        cache.save(article(url))
        let variant = URL(string: url.absoluteString + "?utm_source=x#top")!
        let preloader = makePreloader { _ in throw FetchFailure() }
        preloader.preload(url: variant)
        XCTAssertEqual(preloader.status, .ready)
        XCTAssertTrue(fetchedURLs.isEmpty)
    }

    func testFailedURLCanBeRetried() async {
        let url = makeURL()
        var shouldFail = true
        let preloader = makePreloader { requested in
            if shouldFail { throw FetchFailure() }
            return self.article(requested)
        }
        preloader.preload(url: url)
        await waitUntil(preloader, .failed)
        shouldFail = false
        preloader.preload(url: url, retryFailed: true)
        await waitUntil(preloader, .ready)
        XCTAssertEqual(preloader.status, .ready)
    }

    func testYouTubeTranscriptLinksAreNotPreloaded() {
        let preloader = makePreloader { self.article($0) }
        preloader.preload(url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!)
        XCTAssertEqual(preloader.status, .idle)
        XCTAssertTrue(fetchedURLs.isEmpty)
    }

    // MARK: - Cancellation

    func testCancelDropsInFlightResultAndReleasesWebView() async {
        let url = makeURL()
        let preloader = makePreloader { requested in
            try await Task.sleep(for: .milliseconds(150))
            return self.article(requested)
        }
        preloader.preload(url: url)
        preloader.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(preloader.status, .idle)
        XCTAssertNil(cache.article(for: url), "a cancelled preload must not write the cache")
        XCTAssertTrue(warmer.warmedURLs.isEmpty)
        XCTAssertGreaterThan(warmer.releaseCount, 0)
    }

    func testNewURLReplacesOlderRequest() async {
        let slow = makeURL()
        let fast = makeURL()
        let preloader = makePreloader { requested in
            if requested == slow { try await Task.sleep(for: .milliseconds(150)) }
            return self.article(requested)
        }
        preloader.preload(url: slow)
        preloader.preload(url: fast)
        await waitUntil(preloader, .ready)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(preloader.currentURL, fast)
        XCTAssertEqual(warmer.warmedURLs, [fast], "only the latest request warms the single web view")
        XCTAssertNil(cache.article(for: slow))
    }

    // MARK: - Bundled sample and history

    func testSamplePreloadNeedsNoNetworkAndSeedsCache() {
        let preloader = makePreloader { _ in throw FetchFailure() }
        preloader.preloadSample()
        XCTAssertEqual(preloader.status, .ready)
        XCTAssertTrue(fetchedURLs.isEmpty)
        XCTAssertEqual(cache.article(for: ReaderSampleArticle.url)?.title, ReaderSampleArticle.title)
        XCTAssertEqual(warmer.warmedURLs, [ReaderSampleArticle.url])
    }

    func testPreloadingNeverAddsToLastOpened() async {
        let store = LastOpenedStore.shared
        let before = store.items.map(\.id)
        let url = makeURL()
        let preloader = makePreloader { self.article($0) }
        preloader.preloadSample()
        preloader.preload(url: url)
        await waitUntil(preloader, .ready)
        XCTAssertEqual(store.items.map(\.id), before)
    }
}
