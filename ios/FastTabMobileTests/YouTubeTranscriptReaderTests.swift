import XCTest
import IndieTranscripts
@testable import FastTabMobile

final class YouTubeTranscriptRouteTests: XCTestCase {
    func testWatchURLRoutesToTranscript() {
        XCTAssertEqual(ReaderContentRoute.route(for: URL(string: "https://www.youtube.com/watch?v=8jPQjjsBbIc")!),
                       .youtubeTranscript(videoID: "8jPQjjsBbIc"))
        XCTAssertEqual(ReaderContentRoute.route(for: URL(string: "https://youtu.be/8jPQjjsBbIc")!),
                       .youtubeTranscript(videoID: "8jPQjjsBbIc"))
    }

    func testShortStaysOnArticlePath() {
        XCTAssertEqual(ReaderContentRoute.route(for: URL(string: "https://www.youtube.com/shorts/8jPQjjsBbIc")!), .article)
    }

    func testNormalPageStaysOnArticlePath() {
        XCTAssertEqual(ReaderContentRoute.route(for: URL(string: "https://example.com/post")!), .article)
        XCTAssertEqual(ReaderContentRoute.route(for: URL(string: "https://www.youtube.com/@channel")!), .article)
    }
}

final class TranscriptArticleBuilderTests: XCTestCase {
    private let url = URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!

    func testTimestampsAndStartMsPerParagraph() {
        let html = TranscriptArticleBuilder.html(for: [
            TranscriptParagraph(startMs: 0, endMs: 5_000, text: "Hello."),
            TranscriptParagraph(startMs: 3_725_000, endMs: 3_730_000, text: "Later."),
        ])
        XCTAssertTrue(html.contains("<p class=\"ft-transcript-paragraph\" data-start-ms=\"0\">"))
        XCTAssertTrue(html.contains("data-start-ms=\"0\">0:00</button> Hello.</p>"))
        XCTAssertTrue(html.contains("data-start-ms=\"3725000\">1:02:05</button> Later.</p>"))
    }

    func testTimestampFormat() {
        XCTAssertEqual(TranscriptArticleBuilder.timestamp(ms: 65_400), "1:05")
        XCTAssertEqual(TranscriptArticleBuilder.timestamp(ms: 3_600_000), "1:00:00")
        XCTAssertEqual(TranscriptArticleBuilder.timestamp(ms: -5), "0:00")
    }

    func testCaptionTextIsEscaped() {
        let sentinel = "<b>INJECTED</b> $(echo INJECTED) \"q\" 'a' & more"
        let html = TranscriptArticleBuilder.html(for: [TranscriptParagraph(startMs: 0, endMs: 1, text: sentinel)])
        XCTAssertFalse(html.contains("<b>"))
        XCTAssertTrue(html.contains("&lt;b&gt;INJECTED&lt;/b&gt; $(echo INJECTED) &quot;q&quot; &#39;a&#39; &amp; more"))
    }

    func testArticleCarriesVideoIDTitleAndChannelByline() {
        let transcript = Transcript(videoId: "abcdefghijk", title: nil, lang: "en", kind: .asr, availableLangs: ["en"],
                                    lines: [TranscriptLine(startMs: 0, durationMs: 2_000, text: "Hi there.")])
        let article = TranscriptArticleBuilder.article(from: transcript, url: url, videoID: "abcdefghijk",
                                                       title: "Opened title", channel: "Some Channel")
        XCTAssertEqual(article.youtubeVideoID, "abcdefghijk")
        XCTAssertEqual(article.title, "Opened title")
        XCTAssertEqual(article.byline, "Some Channel · Auto-generated transcript")
        XCTAssertEqual(article.siteName, "YouTube")
    }

    func testOldCacheEntriesDecodeWithoutVideoID() throws {
        let json = #"{"title":"t","byline":"","siteName":"","content":"c","excerpt":"","url":"https://e.com","extractedAt":0}"#
        let article = try JSONDecoder().decode(ReaderArticle.self, from: Data(json.utf8))
        XCTAssertNil(article.youtubeVideoID)
    }

    func testPreferredLangIsBareLanguageCode() {
        XCTAssertEqual(YouTubeTranscriptLoader.preferredLang(["vi-VN", "en"]), "vi")
        XCTAssertNil(YouTubeTranscriptLoader.preferredLang([]))
    }
}

final class TranscriptErrorMappingTests: XCTestCase {
    func testServerErrorsMapToFriendlyMessages() {
        XCTAssertEqual(TranscriptReaderError(TranscriptError.noCaptions).localizedDescription, "No transcript for this video")
        XCTAssertEqual(TranscriptReaderError(TranscriptError.loginRequired).localizedDescription,
                       "This video needs sign-in on YouTube")
        XCTAssertEqual(TranscriptReaderError(TranscriptError.server(status: 500)), .unavailable)
        XCTAssertEqual(TranscriptReaderError(TranscriptError.notSignedIn), .needsAccount)
        XCTAssertEqual(TranscriptReaderError(URLError(.notConnectedToInternet)), .unavailable)
    }

    func testClient404BecomesNoTranscript() async {
        let client = TranscriptClient(baseURL: URL(string: "https://stub.invalid")!, session: StubTranscriptProtocol.session(status: 404))
        do {
            _ = try await client.transcript(videoId: "abcdefghijk", lang: "en")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(TranscriptReaderError(error), .noTranscript)
        }
    }

    @MainActor
    func testViewModelShowsTranscriptFailureForYouTube() async {
        let loader = YouTubeTranscriptLoader(fetchTranscript: { _, _ in throw TranscriptError.loginRequired },
                                             fetchChannel: { _ in nil })
        let vm = ReaderViewModel(url: URL(string: "https://www.youtube.com/watch?v=zzTestLogin")!, title: "t",
                                 statsRecorder: .isolatedForTests(), transcriptLoader: loader)
        await vm.extractIfNeeded()
        XCTAssertEqual(vm.transcriptFailure, .needsSignIn)
    }

    @MainActor
    func testViewModelLoadsTranscriptArticle() async {
        let loader = YouTubeTranscriptLoader(
            fetchTranscript: { id, _ in
                Transcript(videoId: id, lang: "en", kind: .manual, availableLangs: ["en"],
                           lines: [TranscriptLine(startMs: 0, durationMs: 1_000, text: "Only line.")])
            },
            fetchChannel: { _ in "Chan" })
        let vm = ReaderViewModel(url: URL(string: "https://www.youtube.com/watch?v=zzTestLoad1")!, title: "t",
                                 statsRecorder: .isolatedForTests(), transcriptLoader: loader)
        await vm.extractIfNeeded(force: true)
        guard case .loaded(let article) = vm.loadState else { return XCTFail("not loaded") }
        XCTAssertEqual(article.youtubeVideoID, "zzTestLoad1")
        XCTAssertTrue(article.content.contains("Only line."))
    }
}

/// Answers every request with a fixed status and an empty body.
final class StubTranscriptProtocol: URLProtocol {
    static var status = 200

    static func session(status: Int) -> URLSession {
        Self.status = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTranscriptProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
