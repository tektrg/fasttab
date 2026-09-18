import XCTest
import CryptoKit
import WebKit
@testable import FastTabMobile

@MainActor
final class ReaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.readerReadingProgressV1")
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.readerHighlightsV1")
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.lastOpenedReadingHistoryV1")
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.readerArticleCacheIndexV1")
        ReaderArticleCache.shared.clear()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.readerReadingProgressV1")
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.readerHighlightsV1")
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.lastOpenedReadingHistoryV1")
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.readerArticleCacheIndexV1")
        ReaderArticleCache.shared.clear()
        super.tearDown()
    }

    func testReadingProgressClampingAndPersistence() {
        let store = ReaderReadingProgress.shared
        let testURL = URL(string: "https://example.com/article1")!

        store.set(progress: 0.45, for: testURL)
        XCTAssertEqual(store.progress(for: testURL), 0.45, accuracy: 0.001)

        store.set(progress: -0.5, for: testURL)
        XCTAssertEqual(store.progress(for: testURL), 0.0, accuracy: 0.001)

        store.set(progress: 1.5, for: testURL)
        XCTAssertEqual(store.progress(for: testURL), 1.0, accuracy: 0.001)
    }

    func testHighlightStoreAddAndRemove() {
        let store = ReaderHighlightStore.shared
        let url = URL(string: "https://example.com/test-article")!

        XCTAssertTrue(store.highlights(for: url).isEmpty)

        let h1 = ReaderHighlight(
            id: "hl-1",
            urlKey: "https://example.com/test-article",
            selectedText: "Hello world",
            color: .yellow,
            serializedRange: "{\"start\":0,\"len\":11}"
        )
        store.add(h1)

        let loaded = store.highlights(for: url)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "hl-1")
        XCTAssertEqual(loaded.first?.selectedText, "Hello world")
        XCTAssertEqual(loaded.first?.color, .yellow)

        store.remove(id: "hl-1", url: url)
        XCTAssertTrue(store.highlights(for: url).isEmpty)
    }

    func testHighlightStoreRemoveAll() {
        let store = ReaderHighlightStore.shared
        let url = URL(string: "https://example.com/multi")!

        let h1 = ReaderHighlight(
            id: "h1",
            urlKey: "https://example.com/multi",
            selectedText: "One",
            color: .green,
            serializedRange: "{\"start\":0,\"len\":3}"
        )
        let h2 = ReaderHighlight(
            id: "h2",
            urlKey: "https://example.com/multi",
            selectedText: "Two",
            color: .pink,
            serializedRange: "{\"start\":10,\"len\":3}"
        )
        store.add(h1)
        store.add(h2)
        XCTAssertEqual(store.highlights(for: url).count, 2)

        store.removeAll(for: url)
        XCTAssertTrue(store.highlights(for: url).isEmpty)
    }

    func testLastOpenedStorePreservesReadingProgressOnReopen() {
        let store = LastOpenedStore.shared
        let url = URL(string: "https://example.com/preserve")!

        store.recordOpened(url: url, title: "Test Article")
        XCTAssertEqual(store.items.first?.url, "https://example.com/preserve")
        XCTAssertEqual(store.items.first?.readingProgress, 0.0)

        store.updateProgress(url: url, progress: 0.68)
        XCTAssertEqual(store.items.first?.readingProgress, 0.68)

        store.recordOpened(url: url, title: "Test Article Updated")
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.readingProgress, 0.68)
        XCTAssertEqual(store.items.first?.title, "Test Article Updated")
    }

    func testReaderArticleValidation() {
        let valid = ReaderArticle(
            title: "Swift Concurrency",
            byline: "Apple",
            siteName: "developer.apple.com",
            content: "<p>Swift is modern.</p>",
            excerpt: "Swift is modern.",
            url: URL(string: "https://developer.apple.com/swift")!,
            extractedAt: Date()
        )
        XCTAssertFalse(valid.isEmpty)

        let empty = ReaderArticle(
            title: "",
            byline: "",
            siteName: "",
            content: "   \n\t  ",
            excerpt: "",
            url: URL(string: "https://example.com")!,
            extractedAt: Date()
        )
        XCTAssertTrue(empty.isEmpty)
    }

    func testHighlightColorProperties() {
        XCTAssertEqual(HighlightColor.yellow.label, "Yellow")
        XCTAssertEqual(HighlightColor.green.label, "Green")
        XCTAssertEqual(HighlightColor.blue.label, "Blue")
        XCTAssertEqual(HighlightColor.pink.label, "Pink")
        XCTAssertTrue(HighlightColor.yellow.cssRGBA.contains("rgba"))
    }

    func testHighlightWithQuotesAndEmojis() {
        let store = ReaderHighlightStore.shared
        let url = URL(string: "https://example.com/quotes-test")!

        let textWithQuotes = "She said: \"It's amazing!\" 🚀 & \\backslash\\"
        let rangeJSON = "{\"text\":\"\(textWithQuotes.replacingOccurrences(of: "\"", with: "\\\""))\",\"start\":12,\"len\":35}"

        let h = ReaderHighlight(
            id: "hl-quote-1",
            urlKey: "https://example.com/quotes-test",
            selectedText: textWithQuotes,
            color: .blue,
            serializedRange: rangeJSON
        )

        store.add(h)
        let loaded = store.highlights(for: url)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.selectedText, textWithQuotes)
        XCTAssertEqual(loaded.first?.serializedRange, rangeJSON)

        // Verify JSON encoding of payload doesn't crash or corrupt
        let payload: [String: String] = [
            "id": h.id,
            "range": h.serializedRange,
            "color": h.color.cssRGBA
        ]
        let data = try? JSONEncoder().encode(payload)
        XCTAssertNotNil(data)
        if let data, let jsonStr = String(data: data, encoding: .utf8) {
            XCTAssertTrue(jsonStr.contains("hl-quote-1"))
            // Verify round-trip decoding
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            XCTAssertEqual(decoded?["range"], rangeJSON)
        }
    }

    func testViewModelIsFailedHelper() {
        let vm = ReaderViewModel(url: URL(string: "https://example.com")!, title: "Test")
        XCTAssertFalse(vm.isFailed)

        struct DummyError: Error {}
        vm.loadState = .failed(DummyError())
        XCTAssertTrue(vm.isFailed)

        vm.loadState = .loaded(ReaderArticle(
            title: "Test",
            byline: "",
            siteName: "",
            content: "<p>Content</p>",
            excerpt: "",
            url: URL(string: "https://example.com")!,
            extractedAt: Date()
        ))
        XCTAssertFalse(vm.isFailed)
    }

    func testReaderArticleCacheSaveAndRetrieve() {
        let cache = ReaderArticleCache.shared
        let url = URL(string: "https://example.com/cached-article")!

        XCTAssertFalse(cache.hasCachedArticle(for: url))
        XCTAssertNil(cache.article(for: url))

        let article = ReaderArticle(
            title: "Cached Title",
            byline: "Author",
            siteName: "Example",
            content: "<p>Cached article content</p>",
            excerpt: "Cached excerpt",
            url: url,
            extractedAt: Date()
        )

        cache.save(article)

        XCTAssertTrue(cache.hasCachedArticle(for: url))
        let retrieved = cache.article(for: url)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.title, "Cached Title")
        XCTAssertEqual(retrieved?.content, "<p>Cached article content</p>")
        XCTAssertEqual(retrieved?.url, url)

        cache.remove(for: url)
        XCTAssertFalse(cache.hasCachedArticle(for: url))
        XCTAssertNil(cache.article(for: url))
    }

    func testReaderArticleCacheDiskPersistence() {
        let url = URL(string: "https://example.com/disk-article")!
        let article = ReaderArticle(
            title: "Disk Title",
            content: "<p>Disk content</p>",
            url: url
        )

        let cache1 = ReaderArticleCache.shared
        cache1.save(article)

        // Create a separate instance pointing to same file storage to verify disk read
        let cache2 = ReaderArticleCache()
        let retrieved = cache2.article(for: url)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.title, "Disk Title")
        XCTAssertEqual(retrieved?.content, "<p>Disk content</p>")
    }

    func testViewModelLoadsFromCacheInstantly() {
        let url = URL(string: "https://example.com/instant-load")!
        let article = ReaderArticle(
            title: "Instant Title",
            content: "<p>Instant Content</p>",
            url: url
        )
        ReaderArticleCache.shared.save(article)

        let vm = ReaderViewModel(url: url, title: "Initial Title")
        XCTAssertEqual(vm.loadState, .idle)

        // On appear / loadInitialState, article is immediately restored without extraction
        vm.loadInitialState()

        if case .loaded(let loadedArticle) = vm.loadState {
            XCTAssertEqual(loadedArticle.title, "Instant Title")
            XCTAssertEqual(loadedArticle.content, "<p>Instant Content</p>")
        } else {
            XCTFail("Expected ViewModel to transition to .loaded immediately from cache")
        }
    }

    func testReaderArticleCacheLRUEvictionCap50() {
        let cache = ReaderArticleCache.shared

        // Save 52 articles
        for i in 1...52 {
            let article = ReaderArticle(
                title: "Article \(i)",
                content: "<p>Content \(i)</p>",
                url: URL(string: "https://example.com/article-\(i)")!
            )
            cache.save(article)
        }

        // Articles 1 and 2 should be evicted (oldest)
        XCTAssertNil(cache.article(for: URL(string: "https://example.com/article-1")!))
        XCTAssertNil(cache.article(for: URL(string: "https://example.com/article-2")!))

        // Articles 3 through 52 should be present
        for i in 3...52 {
            let article = cache.article(for: URL(string: "https://example.com/article-\(i)")!)
            XCTAssertNotNil(article, "Article \(i) should still be in cache")
            XCTAssertEqual(article?.title, "Article \(i)")
        }
    }

    func testReaderArticleCacheLRUAccessOrderPreservation() {
        let cache = ReaderArticleCache.shared

        // Save 50 articles
        for i in 1...50 {
            let article = ReaderArticle(
                title: "Article \(i)",
                content: "<p>Content \(i)</p>",
                url: URL(string: "https://example.com/article-\(i)")!
            )
            cache.save(article)
        }

        // Access article 1 to promote its recency
        let article1 = cache.article(for: URL(string: "https://example.com/article-1")!)
        XCTAssertNotNil(article1)

        // Save article 51 — should evict article 2 (oldest unaccessed), NOT article 1
        let article51 = ReaderArticle(
            title: "Article 51",
            content: "<p>Content 51</p>",
            url: URL(string: "https://example.com/article-51")!
        )
        cache.save(article51)

        // Article 1 is preserved because it was recently accessed
        XCTAssertNotNil(cache.article(for: URL(string: "https://example.com/article-1")!))
        // Article 2 was evicted as the least recently used
        XCTAssertNil(cache.article(for: URL(string: "https://example.com/article-2")!))
        // Article 51 is present
        XCTAssertNotNil(cache.article(for: URL(string: "https://example.com/article-51")!))
    }

    func testReaderArticleCacheEmptyArticleNotSaved() {
        let cache = ReaderArticleCache.shared
        let url = URL(string: "https://example.com/empty-article")!

        let emptyArticle = ReaderArticle(
            title: "Empty Article",
            content: "   \n\t  ",
            url: url
        )
        cache.save(emptyArticle)

        XCTAssertFalse(cache.hasCachedArticle(for: url))
        XCTAssertNil(cache.article(for: url))
    }

    func testReaderArticleCacheCorruptedFileRecovery() {
        let cache = ReaderArticleCache.shared
        let url = URL(string: "https://example.com/corrupt-test")!

        let article = ReaderArticle(
            title: "Original",
            content: "<p>Original</p>",
            url: url
        )
        cache.save(article)
        XCTAssertTrue(cache.hasCachedArticle(for: url))

        // Directly overwrite the disk cache file with corrupted non-JSON data
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dirURL = cachesDir.appendingPathComponent("FastTabReaderArticles", isDirectory: true)

        let key = url.readerCanonicalKey
        let hash = SHA256.hash(data: Data(key.utf8))
        let filename = hash.compactMap { String(format: "%02x", $0) }.joined() + ".json"
        let fileURL = dirURL.appendingPathComponent(filename)

        try? Data("CORRUPTED_NON_JSON_DATA".utf8).write(to: fileURL)

        // A new cache instance checking this URL should gracefully return nil and remove corrupted file
        let freshCache = ReaderArticleCache()
        let result = freshCache.article(for: url)
        XCTAssertNil(result)
        XCTAssertFalse(freshCache.hasCachedArticle(for: url))
    }

    func testReaderCanonicalKeyNormalizesFragmentsAndTrackingParams() {
        let base = URL(string: "https://example.com/article")!
        let withAnchor = URL(string: "https://example.com/article#section-2")!
        let withTracking = URL(string: "https://example.com/article?utm_source=newsletter&utm_medium=email&utm_campaign=daily")!
        let withAnchorAndTracking = URL(string: "https://example.com/article?utm_source=twitter#top")!
        let mixedCasing = URL(string: "HTTPS://Example.COM/article")!

        XCTAssertEqual(base.readerCanonicalKey, "https://example.com/article")
        XCTAssertEqual(withAnchor.readerCanonicalKey, "https://example.com/article")
        XCTAssertEqual(withTracking.readerCanonicalKey, "https://example.com/article")
        XCTAssertEqual(withAnchorAndTracking.readerCanonicalKey, "https://example.com/article")
        XCTAssertEqual(mixedCasing.readerCanonicalKey, "https://example.com/article")

        // Legitimate non-tracking query parameters are preserved and sorted
        let queryA = URL(string: "https://example.com/post?id=123&page=2")!
        let queryB = URL(string: "https://example.com/post?page=2&id=123")!
        XCTAssertEqual(queryA.readerCanonicalKey, queryB.readerCanonicalKey)
        XCTAssertEqual(queryA.readerCanonicalKey, "https://example.com/post?id=123&page=2")
    }

    func testReaderArticleCacheAnchorAndTrackingNormalizationHit() {
        let cache = ReaderArticleCache.shared
        let urlWithAnchor = URL(string: "https://example.com/anchor-story#intro")!
        let cleanURL = URL(string: "https://example.com/anchor-story")!
        let urlWithTracking = URL(string: "https://example.com/anchor-story?utm_source=feed&ref=rss#comments")!

        let article = ReaderArticle(
            title: "Anchor Story",
            content: "<p>Content with anchor</p>",
            url: urlWithAnchor
        )
        cache.save(article)

        // Clean URL should hit cache
        XCTAssertTrue(cache.hasCachedArticle(for: cleanURL))
        let hitClean = cache.article(for: cleanURL)
        XCTAssertNotNil(hitClean)
        XCTAssertEqual(hitClean?.title, "Anchor Story")

        // URL with tracking and different fragment should hit cache
        XCTAssertTrue(cache.hasCachedArticle(for: urlWithTracking))
        let hitTracking = cache.article(for: urlWithTracking)
        XCTAssertNotNil(hitTracking)
        XCTAssertEqual(hitTracking?.title, "Anchor Story")
    }

    func testReaderArticleCacheMemoryPressureEviction() {
        let cache = ReaderArticleCache.shared
        let url = URL(string: "https://example.com/memory-pressure-test")!
        let article = ReaderArticle(
            title: "Memory Pressure Title",
            content: "<p>Memory pressure content</p>",
            url: url
        )
        cache.save(article)

        // Evict in-memory tier (as when UIApplication.didReceiveMemoryWarningNotification fires)
        cache.clearMemoryTier()

        // Disk tier remains intact and seamlessly restores article
        XCTAssertTrue(cache.hasCachedArticle(for: url))
        let reloaded = cache.article(for: url)
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(reloaded?.title, "Memory Pressure Title")
    }

    func testNormalCacheMissDoesNotWriteToUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "FastTabMobile.readerArticleCacheIndexV1")
        let cache = ReaderArticleCache()
        let nonExistentURL = URL(string: "https://example.com/never-cached-article")!

        let result = cache.article(for: nonExistentURL)
        XCTAssertNil(result)

        // Normal cache miss should NOT write index to UserDefaults
        XCTAssertNil(UserDefaults.standard.data(forKey: "FastTabMobile.readerArticleCacheIndexV1"))
    }

    func testViewModelInstantLoadFromCacheInLoadInitialState() {
        let url = URL(string: "https://example.com/frame-zero-test")!
        let article = ReaderArticle(
            title: "Frame Zero Title",
            content: "<p>Frame Zero Content</p>",
            url: url
        )
        ReaderArticleCache.shared.save(article)
        ReaderReadingProgress.shared.set(progress: 0.72, for: url)

        let vm = ReaderViewModel(url: url, title: "Initial Title")
        XCTAssertEqual(vm.loadState, .idle)

        vm.loadInitialState()
        if case .loaded(let loaded) = vm.loadState {
            XCTAssertEqual(loaded.title, "Frame Zero Title")
        } else {
            XCTFail("ViewModel should have .loaded state immediately from cache in loadInitialState")
        }
        XCTAssertEqual(vm.scrollProgress, 0.72, accuracy: 0.001)
    }

    func testViewModelUpdateScrollProgressImmediateFlushesToStores() {
        let url = URL(string: "https://example.com/immediate-flush")!
        let vm = ReaderViewModel(url: url, title: "Immediate Flush Test")
        LastOpenedStore.shared.recordOpened(url: url, title: "Immediate Flush Test")

        vm.updateScrollProgress(0.85, immediate: true)

        XCTAssertEqual(vm.scrollProgress, 0.85, accuracy: 0.001)
        XCTAssertEqual(ReaderReadingProgress.shared.progress(for: url), 0.85, accuracy: 0.001)
        XCTAssertEqual(LastOpenedStore.shared.items.first(where: { $0.url == url.absoluteString })?.readingProgress, 0.85)
    }

    func testViewModelFlushPendingProgressFlushesDebouncedProgress() {
        let url = URL(string: "https://example.com/flush-pending")!
        let vm = ReaderViewModel(url: url, title: "Flush Pending Test")
        LastOpenedStore.shared.recordOpened(url: url, title: "Flush Pending Test")

        // Without immediate, store has old value immediately
        vm.updateScrollProgress(0.62)
        XCTAssertEqual(vm.scrollProgress, 0.62, accuracy: 0.001)

        // Calling flushPendingProgress immediately writes to store
        vm.flushPendingProgress()
        XCTAssertEqual(ReaderReadingProgress.shared.progress(for: url), 0.62, accuracy: 0.001)
        XCTAssertEqual(LastOpenedStore.shared.items.first(where: { $0.url == url.absoluteString })?.readingProgress, 0.62)
    }

    func testRapidScrollUpdatesDoNotInterfereAndLatestPersisted() {
        let url = URL(string: "https://example.com/rapid-scroll")!
        let vm = ReaderViewModel(url: url, title: "Rapid Scroll Test")
        LastOpenedStore.shared.recordOpened(url: url, title: "Rapid Scroll Test")

        // Simulate 20 rapid scroll updates
        for i in 1...20 {
            let progress = Double(i) / 20.0
            vm.updateScrollProgress(progress)
        }

        XCTAssertEqual(vm.scrollProgress, 1.0, accuracy: 0.001)
        vm.flushPendingProgress()
        XCTAssertEqual(ReaderReadingProgress.shared.progress(for: url), 1.0, accuracy: 0.001)
        XCTAssertEqual(LastOpenedStore.shared.items.first(where: { $0.url == url.absoluteString })?.readingProgress, 1.0)
    }

    // MARK: - Twitter / X Embed Tests

    func testLinkPreviewTwitterURLDetection() {
        XCTAssertTrue(LinkPreviewLoader.isTwitterURL(URL(string: "https://x.com/jack/status/20")!))
        XCTAssertTrue(LinkPreviewLoader.isTwitterURL(URL(string: "https://www.x.com/user/status/12345")!))
        XCTAssertTrue(LinkPreviewLoader.isTwitterURL(URL(string: "https://twitter.com/jack/status/20")!))
        XCTAssertTrue(LinkPreviewLoader.isTwitterURL(URL(string: "https://mobile.twitter.com/i/status/999")!))

        XCTAssertFalse(LinkPreviewLoader.isTwitterURL(URL(string: "https://example.com/status/20")!))
        XCTAssertFalse(LinkPreviewLoader.isTwitterURL(URL(string: "https://notx.com/jack")!))
        XCTAssertFalse(LinkPreviewLoader.isTwitterURL(URL(string: "https://google.com")!))
        XCTAssertFalse(LinkPreviewLoader.isTwitterURL(URL(string: "https://vox.com/news")!))
        XCTAssertFalse(LinkPreviewLoader.isTwitterURL(URL(string: "https://dropbox.com")!))
        XCTAssertFalse(LinkPreviewLoader.isTwitterURL(URL(string: "https://netflix.com")!))
    }

    func testExtractTweetSnippetFromOembedHTML() {
        let sampleHTML = "<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">just setting up my twttr &amp; testing &quot;quotes&quot; &#39;apostrophes&#39; &mdash; dashes</p>&mdash; jack (@jack) <a href=\"https://x.com/jack/status/20\">March 21, 2006</a></blockquote>\n<script async src=\"https://platform.x.com/widgets.js\"></script>"

        let snippet = LinkPreviewLoader.extractTweetSnippet(from: sampleHTML)
        XCTAssertEqual(snippet, "just setting up my twttr & testing \"quotes\" 'apostrophes' — dashes")
    }

    func testExtractTweetSnippetDecodesTypographicalQuotesAndAmpersand() {
        let sampleHTML = "<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">It&#8217;s &ldquo;FastTab&rdquo; &amp; &lt;b&gt;awesome&lt;/b&gt;&nbsp;speed!</p></blockquote>"
        let snippet = LinkPreviewLoader.extractTweetSnippet(from: sampleHTML)
        XCTAssertEqual(snippet, "It’s “FastTab” & <b>awesome</b> speed!")
    }

    func testExtractTweetSnippetWithInnerLinks() {
        let sampleHTML = "<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">Check out <a href=\"https://fasttab.app\">FastTab</a> for super fast browsing!</p></blockquote>"
        let snippet = LinkPreviewLoader.extractTweetSnippet(from: sampleHTML)
        XCTAssertEqual(snippet, "Check out FastTab for super fast browsing!")
    }

    func testLinkPreviewTweetProperties() {
        let preview = LinkPreview(
            title: "Test Post",
            image: nil,
            authorName: "Jack Dorsey",
            authorHandle: "@jack",
            snippetText: "just setting up my twttr",
            isTweet: true
        )

        XCTAssertTrue(preview.isTweet)
        XCTAssertEqual(preview.authorName, "Jack Dorsey")
        XCTAssertEqual(preview.authorHandle, "@jack")
        XCTAssertEqual(preview.snippetText, "just setting up my twttr")
        XCTAssertNil(preview.image)
    }

    func testLinkPreviewTwitterStatusURLDetection() {
        XCTAssertTrue(LinkPreviewLoader.isTwitterStatusURL(URL(string: "https://x.com/jack/status/20")!))
        XCTAssertTrue(LinkPreviewLoader.isTwitterStatusURL(URL(string: "https://twitter.com/user/status/123456789")!))
        XCTAssertFalse(LinkPreviewLoader.isTwitterStatusURL(URL(string: "https://x.com/jack")!))
        XCTAssertFalse(LinkPreviewLoader.isTwitterStatusURL(URL(string: "https://twitter.com/home")!))
        XCTAssertFalse(LinkPreviewLoader.isTwitterStatusURL(URL(string: "https://example.com/status/20")!))
    }

    func testExtractTweetSnippetPreservesLineBreaks() {
        let sampleHTML = "<blockquote class=\"twitter-tweet\"><p lang=\"en\" dir=\"ltr\">Line 1<br>Line 2<br />Line 3</p></blockquote>"
        let snippet = LinkPreviewLoader.extractTweetSnippet(from: sampleHTML)
        XCTAssertEqual(snippet, "Line 1\nLine 2\nLine 3")
    }

    // MARK: - Twitter Reader Extraction DOM Tests

    func testTwitterExtractionWithModernTailwindMarkup() async throws {
        let html = """
        <html><body>
        <article>
          <div>
            <a href="/jack"><span>Jack Dorsey</span></a>
            <a href="/jack"><span>@jack</span></a>
            <time datetime="2006-03-21T20:50:00.000Z">Mar 21, 2006</time>
          </div>
          <div dir="auto" class="font-chirp max-w-full whitespace-pre-wrap break-words text-text text-body font-normal">
            <span>just setting up my twttr</span>
          </div>
          <img src="https://pbs.twimg.com/media/abc.jpg" />
        </article>
        </body></html>
        """

        let result = try await evaluateTwitterExtraction(html: html)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["title"] as? String, "just setting up my twttr")
        XCTAssertEqual(result?["byline"] as? String, "Jack Dorsey (@jack) · Mar 21, 2006")
        XCTAssertEqual(result?["siteName"] as? String, "X")
        XCTAssertEqual(result?["excerpt"] as? String, "just setting up my twttr")

        let content = (result?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("just setting up my twttr"))
        XCTAssertTrue(content.contains("https://pbs.twimg.com/media/abc.jpg"))
        XCTAssertTrue(content.contains("tweet-body"))
    }

    func testTwitterExtractionImageOnlyPost() async throws {
        let html = """
        <html><body>
        <article>
          <div>
            <a href="/artist"><span>Artist Name</span></a>
            <a href="/artist"><span>@artist</span></a>
            <time datetime="2026-01-01T00:00:00.000Z">Jan 1, 2026</time>
          </div>
          <img src="https://pbs.twimg.com/media/artwork.jpg" />
        </article>
        </body></html>
        """

        let result = try await evaluateTwitterExtraction(html: html)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["title"] as? String, "Post by Artist Name")
        let content = (result?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("https://pbs.twimg.com/media/artwork.jpg"))
        XCTAssertFalse(content.contains("tweet-body"))
    }

    func testTwitterExtractionThreadContinuationFiltersStrangerReplies() async throws {
        let html = """
        <html><body>
        <article>
          <div>
            <a href="/author"><span>Thread Author</span></a>
            <a href="/author"><span>@author</span></a>
          </div>
          <div dir="auto" class="whitespace-pre-wrap">First post in thread</div>
        </article>
        <article>
          <div>
            <a href="/author"><span>Thread Author</span></a>
            <a href="/author"><span>@author</span></a>
          </div>
          <div dir="auto" class="whitespace-pre-wrap">Second post in thread</div>
        </article>
        <article>
          <div>
            <a href="/stranger"><span>Stranger</span></a>
            <a href="/stranger"><span>@stranger</span></a>
          </div>
          <div dir="auto" class="whitespace-pre-wrap">Unrelated third-party reply</div>
        </article>
        </body></html>
        """

        let result = try await evaluateTwitterExtraction(html: html)
        XCTAssertNotNil(result)
        let content = (result?["content"] as? String) ?? ""
        XCTAssertTrue(content.contains("First post in thread"))
        XCTAssertTrue(content.contains("Thread continuation"))
        XCTAssertTrue(content.contains("Second post in thread"))
        XCTAssertFalse(content.contains("Unrelated third-party reply"))
    }

    func testTwitterExtractionUnhydratedPageReturnsNil() async throws {
        let html = "<html><body><div id=\"react-root\"></div></body></html>"
        let result = try await evaluateTwitterExtraction(html: html)
        XCTAssertNil(result)
    }

    // MARK: - Test Helpers

    private func evaluateTwitterExtraction(html: String) async throws -> [String: Any]? {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        return try await withCheckedThrowingContinuation { continuation in
            var strongDelegate: TestNavigationDelegate?
            strongDelegate = TestNavigationDelegate { error in
                if let error = error {
                    continuation.resume(throwing: error)
                    strongDelegate = nil
                    return
                }
                webView.evaluateJavaScript(ReaderExtractor.buildTwitterExtractionScript()) { result, jsError in
                    if let jsError = jsError {
                        continuation.resume(throwing: jsError)
                    } else {
                        continuation.resume(returning: result as? [String: Any])
                    }
                    strongDelegate = nil
                }
            }
            webView.navigationDelegate = strongDelegate
            webView.loadHTMLString(html, baseURL: URL(string: "https://x.com/jack/status/20"))
        }
    }
}

private final class TestNavigationDelegate: NSObject, WKNavigationDelegate {
    private var onFinish: ((Error?) -> Void)?

    init(onFinish: @escaping (Error?) -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?(nil)
        onFinish = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish?(error)
        onFinish = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFinish?(error)
        onFinish = nil
    }
}
