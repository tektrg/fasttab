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

    /// Only the server's `no_captions` 404 (theindie-api ApiError shape) means the video has no transcript.
    func testClient404NoCaptionsBecomesNoTranscript() async {
        let body = Data(#"{"error":{"code":"no_captions","message":"No captions"}}"#.utf8)
        await assertClientError(status: 404, body: body, maps: .noTranscript)
    }

    /// Any other 404 (unknown route, stale deploy) is a server error, not "no transcript".
    func testClientPlain404BecomesUnavailable() async {
        await assertClientError(status: 404, body: Data(), maps: .unavailable)
    }

    private func assertClientError(status: Int, body: Data, maps expected: TranscriptReaderError,
                                   line: UInt = #line) async {
        let client = TranscriptClient(baseURL: URL(string: "https://stub.invalid")!,
                                      session: StubTranscriptProtocol.session(status: status, body: body))
        do {
            _ = try await client.transcript(videoId: "abcdefghijk", lang: "en")
            XCTFail("expected an error", line: line)
        } catch {
            XCTAssertEqual(TranscriptReaderError(error), expected, line: line)
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

    func testFailureViewOffersSignInOnlyWithoutAccount() {
        XCTAssertEqual(TranscriptFailureView.Action(.needsAccount), .signIn)
        XCTAssertEqual(TranscriptFailureView.Action(.unavailable), .retry)
        XCTAssertEqual(TranscriptFailureView.Action(.noTranscript), .none)
        XCTAssertEqual(TranscriptFailureView.Action(.needsSignIn), .none)
        XCTAssertEqual(TranscriptReaderError.needsAccount.localizedDescription, "Sign in to get transcripts")
    }

    /// Signed out → the failure view's sign-in → its retry reloads, now with the token.
    @MainActor
    func testRetryAfterSignInLoadsTranscript() async {
        let signedIn = SignInFlag()
        let loader = YouTubeTranscriptLoader(
            fetchTranscript: { id, _ in
                guard signedIn.value else { throw TranscriptError.notSignedIn }
                return Transcript(videoId: id, lang: "en", kind: .manual, availableLangs: ["en"],
                                  lines: [TranscriptLine(startMs: 0, durationMs: 1_000, text: "After sign-in.")])
            },
            fetchChannel: { _ in nil })
        let vm = ReaderViewModel(url: URL(string: "https://www.youtube.com/watch?v=zzTestSignI")!, title: "t",
                                 statsRecorder: .isolatedForTests(), transcriptLoader: loader)
        await vm.extractIfNeeded(force: true)
        XCTAssertEqual(vm.transcriptFailure, .needsAccount)

        signedIn.value = true
        await vm.reloadArticle()
        guard case .loaded(let article) = vm.loadState else { return XCTFail("not loaded after sign-in") }
        XCTAssertTrue(article.content.contains("After sign-in."))
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

/// Server refuses (LOGIN_REQUIRED / 502) → on-device fetch → background upload.
final class YouTubeTranscriptFallbackTests: XCTestCase {
    private let phoneCopy = Transcript(videoId: "zzFallback1", lang: "en", kind: .asr, availableLangs: ["en"],
                                       lines: [TranscriptLine(startMs: 0, durationMs: 1_000, text: "$(echo INJECTED) on device")])

    private func loader(server: TranscriptError, device: @escaping @Sendable () throws -> Transcript,
                        uploads: UploadLog) -> YouTubeTranscriptLoader {
        YouTubeTranscriptLoader(fetchTranscript: { _, _ in throw server }, fetchChannel: { _ in nil },
                                fetchOnDevice: { _, _ in try device() },
                                uploadTranscript: { transcript, lang in uploads.record(transcript, lang) })
    }

    func testLoginRequiredFallsBackToDeviceAndUploads() async throws {
        let uploads = UploadLog(expectation(description: "upload"))
        let copy = phoneCopy
        let result = try await loader(server: .loginRequired, device: { copy }, uploads: uploads)
            .transcript(videoID: "zzFallback1", lang: nil)
        XCTAssertEqual(result, copy)
        await fulfillment(of: [uploads.expectation!], timeout: 2)
        XCTAssertEqual(uploads.lang, "en")
        XCTAssertEqual(uploads.transcript, copy)
    }

    func testUpstream502FallsBackAndUploadErrorIsIgnored() async throws {
        let copy = phoneCopy
        let failing = YouTubeTranscriptLoader(fetchTranscript: { _, _ in throw TranscriptError.server(status: 502) },
                                              fetchChannel: { _ in nil }, fetchOnDevice: { _, _ in copy },
                                              uploadTranscript: { _, _ in throw TranscriptError.server(status: 429) })
        let result = try await failing.transcript(videoID: "zzFallback1", lang: "vi")
        XCTAssertEqual(result, copy)
    }

    func testDeviceLoginRequiredShowsNeedsSignIn() async {
        let uploads = UploadLog(nil)
        do {
            _ = try await loader(server: .loginRequired, device: { throw YouTubeCaptionError.loginRequired }, uploads: uploads)
                .transcript(videoID: "zzFallback1", lang: "en")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(TranscriptReaderError(error), .needsSignIn)
        }
        XCTAssertNil(uploads.transcript)
    }

    func testDeviceUpstreamFailureKeepsServerError() async {
        do {
            _ = try await loader(server: .server(status: 502), device: { throw YouTubeCaptionError.upstream("x") }, uploads: UploadLog(nil))
                .transcript(videoID: "zzFallback1", lang: "en")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? TranscriptError, .server(status: 502))
        }
    }

    func testOtherServerErrorsNeverTouchTheDevice() async {
        for serverError in [TranscriptError.noCaptions, .notSignedIn, .powerUpDisabled, .server(status: 500)] {
            do {
                _ = try await loader(server: serverError, device: { XCTFail("device fetch"); throw YouTubeCaptionError.noCaptions },
                                     uploads: UploadLog(nil)).transcript(videoID: "zzFallback1", lang: "en")
            } catch {
                XCTAssertEqual(error as? TranscriptError, serverError)
            }
        }
    }
}

final class UploadLog: @unchecked Sendable {
    let expectation: XCTestExpectation?
    private(set) var transcript: Transcript?
    private(set) var lang: String?
    init(_ expectation: XCTestExpectation?) { self.expectation = expectation }
    func record(_ transcript: Transcript, _ lang: String) {
        self.transcript = transcript
        self.lang = lang
        expectation?.fulfill()
    }
}

/// Stands in for "a session token is in the keychain now".
final class SignInFlag: @unchecked Sendable {
    var value = false
}

/// Answers every request with a fixed status and an empty body.
final class StubTranscriptProtocol: URLProtocol {
    static var status = 200
    static var body = Data()

    static func session(status: Int, body: Data = Data()) -> URLSession {
        Self.status = status
        Self.body = body
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTranscriptProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

import JavaScriptCore

/// Pure JS in reader_template.html between FT_PURE_BEGIN/END, run in JavaScriptCore.
final class TranscriptReadingLineJSTests: XCTestCase {
    private func context() throws -> JSContext {
        let url = try XCTUnwrap(Bundle(for: ReaderWebViewWarmer.self).url(forResource: "reader_template", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let begin = try XCTUnwrap(html.range(of: "// FT_PURE_BEGIN"))
        let end = try XCTUnwrap(html.range(of: "// FT_PURE_END"))
        let ctx = try XCTUnwrap(JSContext())
        ctx.evaluateScript(String(html[begin.lowerBound..<end.lowerBound]))
        return ctx
    }

    private func index(_ tops: [Double], _ line: Double) throws -> Int32 {
        try context().objectForKeyedSubscript("ftParagraphIndexAtLine").call(withArguments: [tops, line]).toInt32()
    }

    func testPicksLastParagraphAboveReadingLine() throws {
        XCTAssertEqual(try index([-300, -40, 120, 400], 200), 2)
        XCTAssertEqual(try index([-300, -40, 220, 400], 200), 1)
    }

    func testLineAboveFirstParagraphIsZero() throws {
        XCTAssertEqual(try index([150, 400], 100), 0)
    }

    func testBoundaryAndEnd() throws {
        XCTAssertEqual(try index([0, 200], 200), 1)
        XCTAssertEqual(try index([-900, -500, -100], 200), 2)
        XCTAssertEqual(try index([], 200), 0)
    }
}
