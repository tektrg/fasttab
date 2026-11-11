import XCTest
@testable import FastTabMobile

/// Test double for the HTTP seam: scripted answers, counts the calls, keeps the last request.
private final class FakeSummaryServer: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<(Int, Data), Error>]
    private(set) var requests: [URLRequest] = []
    private let delay: Duration

    init(_ answers: [Result<(Int, Data), Error>], delay: Duration = .zero) {
        self.answers = answers
        self.delay = delay
    }

    var callCount: Int { lock.withLock { requests.count } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let next: Result<(Int, Data), Error> = lock.withLock {
            requests.append(request)
            return answers.isEmpty ? .success((503, Data())) : answers.removeFirst()
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        let (status, body) = try next.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }

    static func ok(_ summary: String = "**Gist** A short summary.\n**Takeaway**\n  - Detail") -> Result<(Int, Data), Error> {
        let json = #"{"summary":\#(jsonString(summary)),"model":"deepseek/test","promptVersion":1,"defaultInstructionVersion":1,"usage":{"remaining":42}}"#
        return .success((200, Data(json.utf8)))
    }

    static func failure(_ status: Int, _ json: String) -> Result<(Int, Data), Error> { .success((status, Data(json.utf8))) }

    private static func jsonString(_ text: String) -> String {
        String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    }
}

private func makeClient(_ server: FakeSummaryServer) -> ReaderSummaryClient {
    ReaderSummaryClient(endpoint: URL(string: "https://api.example.test/v1/ai/reader-summary")!,
                        headers: { ["X-Install-Id": "install-1", "Authorization": "Bearer t"] },
                        send: { try await server.send($0) })
}

private func longArticle(title: String = "A Long Read", words: Int = 400, url: String = "https://e.com/a") -> ReaderArticle {
    let paragraph = "<p>" + String(repeating: "Sentence about interesting things. ", count: 8) + "</p>"
    let body = String(repeating: paragraph, count: max(1, words / 40))
    return ReaderArticle(title: title, content: body, url: URL(string: url)!)
}

// MARK: - Text preparation

final class ReaderSummaryTextTests: XCTestCase {
    func testShortArticleIsTooShort() {
        let article = ReaderArticle(title: "Hi", content: "<p>Tiny.</p>", url: URL(string: "https://e.com")!)
        XCTAssertEqual(ReaderSummaryText.prepare(article: article), .tooShort)
    }

    func testLongArticleIsReadyWithTitleFirstAndLanguage() {
        guard case .ready(let input) = ReaderSummaryText.prepare(article: longArticle()) else {
            return XCTFail("expected ready")
        }
        XCTAssertTrue(input.text.hasPrefix("A Long Read\n\nSentence about"))
        XCTAssertEqual(input.languageCode, "en")
    }

    func testOverLimitTextKeepsStartAndEndWithinCap() {
        let text = String(repeating: "a", count: 40_000) + String(repeating: "m", count: 50_000) + String(repeating: "z", count: 19_000)
        let capped = ReaderSummaryText.capped(text)
        XCTAssertLessThanOrEqual(capped.count, ReaderSummaryText.maxCharacters)
        XCTAssertTrue(capped.hasPrefix(String(repeating: "a", count: 40_000)))
        XCTAssertTrue(capped.hasSuffix(String(repeating: "z", count: 19_000)))
        XCTAssertTrue(capped.contains("[…]"))
        XCTAssertEqual(ReaderSummaryText.capped("short"), "short")
    }

    func testCapCountsUTF16UnitsLikeTheServer() {
        // 50,000 Characters, but 100,000 UTF-16 units (letter + combining accent): the server would
        // reject it if only Characters were capped.
        let decomposed = String(repeating: "e\u{0301}", count: 50_000)
        let capped = ReaderSummaryText.capped(decomposed)
        XCTAssertLessThanOrEqual(capped.utf16.count, ReaderSummaryText.maxCharacters)
        XCTAssertTrue(capped.contains("[…]"))
    }

    func testCapHoldsEvenForLongGraphemeSequences() {
        let family = String(repeating: "👨‍👩‍👧‍👦", count: 30_000) // 1 Character, 11 UTF-16 units each
        XCTAssertLessThanOrEqual(ReaderSummaryText.capped(family).utf16.count, ReaderSummaryText.maxCharacters)
    }

    func testLanguageCodeShapeFilter() {
        XCTAssertEqual(ReaderSummaryText.acceptableLanguageCode("vi"), "vi")
        XCTAssertEqual(ReaderSummaryText.acceptableLanguageCode("zh-Hans"), "zh-Hans")
        XCTAssertNil(ReaderSummaryText.acceptableLanguageCode("english"))
        XCTAssertNil(ReaderSummaryText.acceptableLanguageCode("en_US"))
    }
}

// MARK: - Client

final class ReaderSummaryClientTests: XCTestCase {
    private let request = ReaderSummaryRequest(text: "body $(echo INJECTED)", languageCode: "en")

    func testSendsIdentityHeadersAndOmitsNilInstruction() async throws {
        let server = FakeSummaryServer([FakeSummaryServer.ok()])
        let response = try await makeClient(server).summarize(request)
        XCTAssertEqual(response.model, "deepseek/test")
        XCTAssertEqual(response.usage?.remaining, 42)
        let sent = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Install-Id"), "install-1")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        XCTAssertEqual(sent.timeoutInterval, ReaderSummaryClient.timeout)
        let body = try XCTUnwrap(sent.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "body $(echo INJECTED)") // sent verbatim, never evaluated
        XCTAssertEqual(json["languageCode"] as? String, "en")
        XCTAssertNil(json["instruction"])
    }

    func testErrorMapping() {
        func map(_ status: Int, _ json: String) -> ReaderSummaryError {
            ReaderSummaryClient.error(status: status, body: Data(json.utf8))
        }
        XCTAssertEqual(map(402, #"{"code":"reader_ai_subscription_required","error":{"code":"reader_ai_subscription_required"}}"#), .subscriptionRequired)
        XCTAssertEqual(map(402, #"{"code":"reader_ai_user_quota","resetsAt":"2026-12-01T00:00:00.000Z"}"#),
                       .quotaExhausted(resetsAt: ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")))
        XCTAssertEqual(map(402, #"{"code":"reader_ai_user_quota"}"#), .quotaExhausted(resetsAt: nil))
        XCTAssertEqual(map(400, #"{"code":"reader_ai_text_too_short"}"#), .tooShort)
        XCTAssertEqual(map(401, #"{"error":{"code":"unauthorized"}}"#), .notSignedIn)
        XCTAssertEqual(map(429, #"{"code":"rate_limited"}"#), .rateLimited)
        XCTAssertEqual(map(503, #"{"code":"reader_ai_ceiling"}"#), .unavailable)
        XCTAssertEqual(map(502, #"{"code":"upstream_failed"}"#), .unavailable)
        XCTAssertEqual(map(500, "not json"), .unavailable)
    }

    func testNetworkFailuresMapToOfflineOrUnavailable() async {
        let offline = FakeSummaryServer([.failure(URLError(.notConnectedToInternet))])
        do { _ = try await makeClient(offline).summarize(request); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ReaderSummaryError, .offline) }
        let other = FakeSummaryServer([.failure(URLError(.cannotParseResponse))])
        do { _ = try await makeClient(other).summarize(request); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ReaderSummaryError, .unavailable) }
    }

    func testSlowServerIsUnavailableNotOffline() async {
        let server = FakeSummaryServer([.failure(URLError(.timedOut))])
        do { _ = try await makeClient(server).summarize(request); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ReaderSummaryError, .unavailable) }
    }

    func testCancellationIsNotAFailure() async {
        let server = FakeSummaryServer([.failure(URLError(.cancelled))])
        do { _ = try await makeClient(server).summarize(request); XCTFail("expected throw") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEmptyOrMalformedSuccessIsUnavailable() async {
        for body in [#"{"summary":"  ","model":"m"}"#, "garbage"] {
            let server = FakeSummaryServer([.success((200, Data(body.utf8)))])
            do { _ = try await makeClient(server).summarize(request); XCTFail("expected throw") }
            catch { XCTAssertEqual(error as? ReaderSummaryError, .unavailable) }
        }
    }
}

// MARK: - Store

final class ReaderSummaryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ReaderSummaryStore { ReaderSummaryStore(directory: directory) }

    override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderSummaries-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func record(digest: String = "d1", instruction: String = "") -> ReaderSummaryRecord {
        ReaderSummaryRecord(textDigest: digest, instructionHash: instruction, summary: "S", model: "m",
                            createdAt: Date(timeIntervalSince1970: 1), defaultInstructionVersion: 1)
    }

    func testRoundTripAndMissAfterTextOrPromptChange() {
        store.save(record(), urlKey: "https://e.com/a")
        XCTAssertEqual(store.record(urlKey: "https://e.com/a", textDigest: "d1", instructionHash: "")?.summary, "S")
        XCTAssertNil(store.record(urlKey: "https://e.com/a", textDigest: "d2", instructionHash: ""))
        XCTAssertNil(store.record(urlKey: "https://e.com/a", textDigest: "d1", instructionHash: "custom"))
        XCTAssertNil(store.record(urlKey: "https://e.com/other", textDigest: "d1", instructionHash: ""))
    }

    func testCorruptFileIsAMissNotACrash() throws {
        store.save(record(), urlKey: "k")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("{broken".utf8).write(to: file)
        XCTAssertNil(store.record(urlKey: "k", textDigest: "d1", instructionHash: ""))
    }

    func testHostileKeyCannotEscapeTheDirectory() throws {
        let hostile = "../../$(echo INJECTED)/x"
        store.save(record(), urlKey: hostile)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].lastPathComponent.contains("INJECTED"))
        XCTAssertEqual(files[0].deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
    }
}

// MARK: - Markdown

final class SummaryMarkdownTests: XCTestCase {
    func testBlocksFromTheDefaultPromptShape() {
        let blocks = SummaryMarkdown.blocks("**Gist** The point.\n\n**Section one**\n  - Sub **bold** fact\n    - Deeper\n* Top bullet\n# Title\n")
        XCTAssertEqual(blocks, [
            .paragraph("**Gist** The point."),
            .paragraph("**Section one**"),
            .bullet(level: 1, text: "Sub **bold** fact"),
            .bullet(level: 2, text: "Deeper"),
            .bullet(level: 0, text: "Top bullet"),
            .heading("Title"),
        ])
    }

    func testEmptyMarkersAreDropped() {
        XCTAssertEqual(SummaryMarkdown.blocks("-\n#\n   \n"), [.paragraph("-")]) // lone "-" has no bullet text
    }

    func testAttributedFallsBackToPlainTextOnBrokenMarkdown() {
        XCTAssertEqual(String(SummaryMarkdown.attributed("plain **bold** text").characters), "plain bold text")
        XCTAssertFalse(String(SummaryMarkdown.attributed("[broken](").characters).isEmpty)
    }
}

// MARK: - Failure wording

final class ReaderSummaryFailureTests: XCTestCase {
    func testRetryAndPaywallFlags() {
        XCTAssertTrue(ReaderSummaryFailure.offline.canRetry)
        XCTAssertTrue(ReaderSummaryFailure.unavailable.canRetry)
        XCTAssertFalse(ReaderSummaryFailure.tooShort.canRetry)
        XCTAssertFalse(ReaderSummaryFailure.quotaExhausted(resetsAt: nil).canRetry)
        XCTAssertTrue(ReaderSummaryFailure.subscriptionRequired.needsPaywall)
        XCTAssertTrue(ReaderSummaryFailure.notSignedIn.needsPaywall)
        XCTAssertFalse(ReaderSummaryFailure.offline.needsPaywall)
    }

    func testRenewalDateIsTheUTCDateTheServerResetsOn() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let resets = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
        let message = ReaderSummaryFailure.quotaExhausted(resetsAt: resets).message(now: now)
        XCTAssertTrue(message.contains("December"), message) // the UTC date, not "November 30" in a US time zone
        XCTAssertFalse(message.contains("November"), message)
    }

    func testQuotaMessageMentionsRenewalOnlyWhenKnownAndFuture() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = ReaderSummaryFailure.quotaExhausted(resetsAt: now.addingTimeInterval(86_400))
        XCTAssertTrue(future.message(now: now).contains("renew"))
        XCTAssertFalse(ReaderSummaryFailure.quotaExhausted(resetsAt: nil).message(now: now).contains("renew"))
        XCTAssertFalse(ReaderSummaryFailure.quotaExhausted(resetsAt: now.addingTimeInterval(-5)).message(now: now).contains("renew"))
    }
}

// MARK: - Model

@MainActor
final class ReaderSummaryModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderSummaryModel-\(UUID())")
        defaults = UserDefaults(suiteName: "ReaderSummaryModelTests-\(UUID())")!
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func model(_ server: FakeSummaryServer, article: ReaderArticle? = nil,
                       consented: Bool = true, instruction: String? = nil) -> ReaderSummaryModel {
        var consent = ReaderSummaryConsent()
        consent.defaults = defaults
        if consented { consent.grant() }
        return ReaderSummaryModel(article: article ?? longArticle(), urlKey: "https://e.com/a",
                                  client: makeClient(server), store: ReaderSummaryStore(directory: directory),
                                  consent: consent, instruction: instruction,
                                  now: { Date(timeIntervalSince1970: 5) })
    }

    private func settle(_ model: ReaderSummaryModel) async {
        for _ in 0..<300 {
            if case .loading = model.state { try? await Task.sleep(for: .milliseconds(10)); continue }
            if model.isRegenerating { try? await Task.sleep(for: .milliseconds(10)); continue }
            return
        }
    }

    func testTooShortNeverCallsTheServer() async {
        let server = FakeSummaryServer([FakeSummaryServer.ok()])
        let short = ReaderArticle(title: "Hi", content: "<p>Tiny.</p>", url: URL(string: "https://e.com/s")!)
        let model = model(server, article: short)
        model.open()
        XCTAssertEqual(model.state, .failed(.tooShort))
        XCTAssertEqual(server.callCount, 0)
    }

    func testNothingIsSentBeforeConsent() async {
        let server = FakeSummaryServer([FakeSummaryServer.ok()])
        let model = model(server, consented: false)
        model.open()
        XCTAssertEqual(model.state, .needsConsent)
        XCTAssertEqual(server.callCount, 0)
        model.acceptConsent()
        await settle(model)
        XCTAssertEqual(server.callCount, 1)
        guard case .ready(let result) = model.state else { return XCTFail("expected ready") }
        XCTAssertFalse(result.fromCache)
        XCTAssertTrue(ReaderSummaryConsent(defaults: defaults).isGranted)
    }

    func testSecondOpenAndANewModelServeTheSavedSummaryWithoutPayingAgain() async {
        let server = FakeSummaryServer([FakeSummaryServer.ok()])
        let first = model(server)
        first.open()
        await settle(first)
        first.open() // sheet reopened: nothing happens
        XCTAssertEqual(server.callCount, 1)

        let second = model(server) // reader reopened later, same text
        second.open()
        guard case .ready(let cached) = second.state else { return XCTFail("expected cached summary") }
        XCTAssertTrue(cached.fromCache)
        XCTAssertEqual(server.callCount, 1)
    }

    func testChangedArticleTextAsksAgain() async {
        let server = FakeSummaryServer([FakeSummaryServer.ok(), FakeSummaryServer.ok("**Gist** Second")])
        let first = model(server)
        first.open(); await settle(first)
        let second = model(server, article: longArticle(title: "Edited Title"))
        second.open(); await settle(second)
        XCTAssertEqual(server.callCount, 2)
    }

    func testRegenerateReplacesTheSavedSummary() async {
        let server = FakeSummaryServer([FakeSummaryServer.ok("**Gist** One"), FakeSummaryServer.ok("**Gist** Two")])
        let model = model(server)
        model.open(); await settle(model)
        model.regenerate(); await settle(model)
        XCTAssertEqual(server.callCount, 2)
        let reopened = self.model(server)
        reopened.open()
        guard case .ready(let result) = reopened.state else { return XCTFail("expected ready") }
        XCTAssertEqual(result.text, "**Gist** Two")
    }

    func testFailureIsShownNotSavedAndRetryWorks() async {
        let server = FakeSummaryServer([.failure(URLError(.notConnectedToInternet)), FakeSummaryServer.ok()])
        let model = model(server)
        model.open(); await settle(model)
        XCTAssertEqual(model.state, .failed(.offline))
        model.retry(); await settle(model)
        guard case .ready = model.state else { return XCTFail("expected ready after retry") }
        XCTAssertEqual(server.callCount, 2)
    }

    func testSubscriptionRequiredFromServerPointsToPaywall() async {
        let server = FakeSummaryServer([FakeSummaryServer.failure(402, #"{"code":"reader_ai_subscription_required"}"#)])
        let model = model(server)
        model.open(); await settle(model)
        XCTAssertEqual(model.state, .failed(.subscriptionRequired))
        XCTAssertTrue(ReaderSummaryFailure.subscriptionRequired.needsPaywall)
    }

    func testRegenerateKeepsTheOldSummaryOnScreenAndOnFailure() async {
        let server = FakeSummaryServer([FakeSummaryServer.ok("**Gist** Old"), .failure(URLError(.notConnectedToInternet))])
        let model = model(server)
        model.open(); await settle(model)
        model.regenerate()
        XCTAssertTrue(model.isRegenerating)
        guard case .ready(let during) = model.state else { return XCTFail("old summary should stay while refreshing") }
        XCTAssertEqual(during.text, "**Gist** Old")
        await settle(model)
        XCTAssertFalse(model.isRegenerating)
        XCTAssertEqual(model.regenerateFailure, .offline)
        guard case .ready(let after) = model.state else { return XCTFail("old summary should survive a failed refresh") }
        XCTAssertEqual(after.text, "**Gist** Old")
    }

    func testTwoModelsForTheSameArticleShareOneRequest() async {
        // Reader closed and reopened while the first request is still running: no second charge.
        let server = FakeSummaryServer([FakeSummaryServer.ok()], delay: .milliseconds(150))
        let first = model(server)
        first.open()
        let second = model(server)
        second.open()
        await settle(first); await settle(second)
        XCTAssertEqual(server.callCount, 1)
        guard case .ready = first.state, case .ready = second.state else { return XCTFail("both should be ready") }
    }

    func testHasSavedSummaryOnlyForTheExactText() async {
        let server = FakeSummaryServer([FakeSummaryServer.ok()])
        let first = model(server)
        XCTAssertFalse(first.hasSavedSummary())
        first.open(); await settle(first)
        XCTAssertTrue(first.hasSavedSummary())
        XCTAssertFalse(model(server, article: longArticle(title: "Edited Title")).hasSavedSummary())
    }

    private func sentInstruction(_ server: FakeSummaryServer, call: Int = 0) throws -> String? {
        let body = try XCTUnwrap(server.requests[call].httpBody)
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["instruction"] as? String
    }

    func testCustomPromptIsSentToTheServer() async throws {
        let server = FakeSummaryServer([FakeSummaryServer.ok()])
        let model = model(server, instruction: "Three bullets only.")
        model.open(); await settle(model)
        XCTAssertEqual(try sentInstruction(server), "Three bullets only.")
    }

    func testDefaultPromptSendsNoInstructionSoServerImprovementsApply() async throws {
        let server = FakeSummaryServer([FakeSummaryServer.ok()])
        let model = model(server)
        model.open(); await settle(model)
        XCTAssertNil(try sentInstruction(server))
    }

    func testEditingThePromptNeverReRunsASavedSummaryOnItsOwn() async {
        let server = FakeSummaryServer([FakeSummaryServer.ok("**Gist** Made with default")])
        let first = model(server)
        first.open(); await settle(first)

        let edited = model(server, instruction: "Three bullets only.") // same article, new prompt
        edited.open()
        guard case .ready(let result) = edited.state else { return XCTFail("old summary should still show") }
        XCTAssertEqual(result.text, "**Gist** Made with default")
        XCTAssertTrue(result.madeWithOtherPrompt)
        XCTAssertEqual(server.callCount, 1) // nothing was charged
        XCTAssertTrue(edited.hasSavedSummary())
    }

    func testRegenerateAfterAPromptEditUsesTheNewPromptAndClearsTheFlag() async throws {
        let server = FakeSummaryServer([FakeSummaryServer.ok("**Gist** Old"), FakeSummaryServer.ok("**Gist** New")])
        let first = model(server)
        first.open(); await settle(first)
        let edited = model(server, instruction: "Three bullets only.")
        edited.open()
        edited.regenerate(); await settle(edited)
        XCTAssertEqual(try sentInstruction(server, call: 1), "Three bullets only.")
        guard case .ready(let result) = edited.state else { return XCTFail("expected ready") }
        XCTAssertEqual(result.text, "**Gist** New")
        XCTAssertFalse(result.madeWithOtherPrompt)
        // Reopening with the same new prompt is a plain cache hit.
        let again = model(server, instruction: "Three bullets only.")
        again.open()
        guard case .ready(let cached) = again.state else { return XCTFail("expected cached") }
        XCTAssertFalse(cached.madeWithOtherPrompt)
        XCTAssertEqual(server.callCount, 2)
    }

    func testModelRemembersWhichPromptItWasBuiltWith() {
        let server = FakeSummaryServer([])
        XCTAssertNil(model(server).instruction)
        XCTAssertEqual(model(server, instruction: "X").instruction, "X")
    }
}

