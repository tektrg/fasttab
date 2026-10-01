import JavaScriptCore
import XCTest
import IndieTextCleanup
import IndieTranscripts
@testable import FastTabMobile

final class TranscriptParagraphTextsTests: XCTestCase {
    func testReadsBackWhatTheBuilderWrote() {
        let texts = ["Plain one.", "<b>$(echo INJECTED)</b> \"q\" 'a' & </button> more"]
        let html = TranscriptArticleBuilder.html(for: texts.enumerated().map {
            TranscriptParagraph(startMs: $0.offset * 1000, endMs: $0.offset * 1000 + 500, text: $0.element)
        })
        XCTAssertEqual(TranscriptArticleBuilder.paragraphTexts(fromHTML: html), texts)
    }

    func testReadsOlderMarkupWithoutTheTextSpan() {
        let html = "<p class=\"ft-transcript-paragraph\" data-start-ms=\"0\"><button type=\"button\" class=\"ft-ts\" "
            + "data-start-ms=\"0\">0:00</button> Old &amp; cached.</p>"
        XCTAssertEqual(TranscriptArticleBuilder.paragraphTexts(fromHTML: html), ["Old & cached."])
    }
}

final class TranscriptCleanupStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsForTheSameTranscriptOnly() {
        let store = TranscriptCleanupStore(directory: directory)
        let originals = ["a", "b"]
        let record = TranscriptCleanupRecord(sourceDigest: TranscriptCleanupStore.digest(originals), texts: ["A.", nil],
                                             instructionVersion: TranscriptCleanup.instructionVersion)
        store.save(record, videoID: "vid_1-x")
        XCTAssertEqual(store.record(videoID: "vid_1-x", originals: originals), record)
        XCTAssertNil(store.record(videoID: "vid_1-x", originals: ["a", "changed"]))
        XCTAssertNil(store.record(videoID: "other", originals: originals))
    }

    func testRecordFromAnOlderInstructionIsCleanedAgain() {
        let store = TranscriptCleanupStore(directory: directory)
        let originals = ["a"]
        store.save(TranscriptCleanupRecord(sourceDigest: TranscriptCleanupStore.digest(originals), texts: ["A."],
                                           instructionVersion: nil), videoID: "v")
        XCTAssertNil(store.record(videoID: "v", originals: originals))
    }

    func testVideoIDCannotEscapeTheFolder() {
        let store = TranscriptCleanupStore(directory: directory)
        store.save(TranscriptCleanupRecord(sourceDigest: "d", texts: []), videoID: "../$(echo INJECTED)")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(files, ["echoINJECTED.json"])
    }
}

/// Uppercases each marked section; counts calls; can report itself unavailable.
private actor FakeModel: TextCleaning {
    var calls = 0
    var unavailable = false
    func setUnavailable(_ on: Bool) { unavailable = on }
    func clean(_ text: String, instruction: String) async throws -> String {
        calls += 1
        if unavailable { throw CleanerUnavailable("busy") }
        return text.uppercased()
    }
}

@MainActor
final class TranscriptCleanupSessionTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defaults = UserDefaults(suiteName: UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func session(_ model: FakeModel, canClean: Bool = true, originals: [String] = ["one two", "three four"],
                         retryDelay: Duration = .seconds(10)) -> TranscriptCleanupSession {
        TranscriptCleanupSession(videoID: "vid", originals: originals, cleaner: model, canClean: canClean,
                                 store: TranscriptCleanupStore(directory: directory), defaults: defaults,
                                 isAppActive: { true }, firstRetryDelay: retryDelay)
    }

    private func waitUntilIdle(_ session: TranscriptCleanupSession) async throws {
        for _ in 0..<200 where session.isCleaning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(session.isCleaning)
    }

    func testOpenCleansSavesAndShowsClean() async throws {
        let model = FakeModel()
        let cleanup = session(model)
        cleanup.open()
        try await waitUntilIdle(cleanup)
        XCTAssertTrue(cleanup.isComplete)
        XCTAssertEqual(cleanup.shownTexts.map(\.text), ["ONE TWO", "THREE FOUR"])
        XCTAssertEqual(cleanup.shownTexts.map(\.v), ["clean", "clean"])

        // Saved once per video: the next open shows it without asking the model.
        let reopened = session(model)
        reopened.open()
        XCTAssertFalse(reopened.isCleaning)
        XCTAssertEqual(reopened.shownTexts.map(\.text), ["ONE TWO", "THREE FOUR"])
        let calls = await model.calls
        XCTAssertEqual(calls, 1)
    }

    func testOriginalToggleShowsOriginalsAndIsRemembered() async throws {
        let cleanup = session(FakeModel())
        cleanup.open()
        try await waitUntilIdle(cleanup)
        cleanup.setShowsClean(false)
        XCTAssertEqual(cleanup.shownTexts.map(\.text), ["one two", "three four"])
        XCTAssertEqual(cleanup.shownTexts.map(\.v), ["original", "original"])
        XCTAssertFalse(session(FakeModel()).showsClean)
    }

    func testNoModelMeansNoToggleAndNoWork() async throws {
        let model = FakeModel()
        let cleanup = session(model, canClean: false)
        cleanup.open()
        XCTAssertFalse(cleanup.isOffered)
        XCTAssertFalse(cleanup.isCleaning)
        XCTAssertEqual(cleanup.shownTexts.map(\.v), ["original", "original"])
    }

    func testUnavailableModelLeavesTheRestForLater() async throws {
        let model = FakeModel()
        await model.setUnavailable(true)
        let cleanup = session(model)
        cleanup.open()
        try await waitUntilIdle(cleanup)
        XCTAssertFalse(cleanup.isComplete)
        XCTAssertEqual(cleanup.shownTexts.map(\.v), ["original", "original"])

        await model.setUnavailable(false)
        cleanup.open()
        try await waitUntilIdle(cleanup)
        XCTAssertTrue(cleanup.isComplete)
    }

    func testRetriesOnItsOwnWhileOpen() async throws {
        let model = FakeModel()
        await model.setUnavailable(true)
        let cleanup = session(model, retryDelay: .milliseconds(50))
        cleanup.open()
        try await waitUntilIdle(cleanup)
        XCTAssertFalse(cleanup.isComplete)
        await model.setUnavailable(false)
        for _ in 0..<100 where !cleanup.isComplete { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cleanup.isComplete)
        cleanup.close()
    }

    func testUnchangedParagraphStaysOriginal() async throws {
        let cleanup = session(FakeModel(), originals: ["ALREADY CLEAN", "lower"])
        cleanup.open()
        try await waitUntilIdle(cleanup)
        XCTAssertEqual(cleanup.shownTexts.map(\.v), ["original", "clean"])
    }

    func testRevisionMovesOnlyWhenShownTextsChange() async throws {
        let cleanup = session(FakeModel())
        let before = cleanup.revision
        cleanup.open()
        try await waitUntilIdle(cleanup)
        let afterClean = cleanup.revision
        XCTAssertGreaterThan(afterClean, before)
        cleanup.setShowsClean(false)
        XCTAssertGreaterThan(cleanup.revision, afterClean)
    }

    func testCloseStopsWithoutLosingProgress() async throws {
        let cleanup = session(FakeModel())
        cleanup.open()
        cleanup.close()
        XCTAssertFalse(cleanup.isCleaning)
    }
}

/// `ftTranscriptHighlightShows` in reader_template.html (FT_PURE block), run in JavaScriptCore.
final class TranscriptHighlightVersionJSTests: XCTestCase {
    private func pure() throws -> JSContext {
        let url = try XCTUnwrap(Bundle(for: ReaderWebViewWarmer.self).url(forResource: "reader_template", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let begin = try XCTUnwrap(html.range(of: "// FT_PURE_BEGIN"))
        let end = try XCTUnwrap(html.range(of: "// FT_PURE_END"))
        let ctx = try XCTUnwrap(JSContext())
        ctx.evaluateScript(String(html[begin.lowerBound..<end.lowerBound]))
        return ctx
    }

    private func shows(_ desc: [String: Any], _ versions: [String]) throws -> Bool {
        try pure().objectForKeyedSubscript("ftTranscriptHighlightShows").call(withArguments: [desc, versions]).toBool()
    }

    private func anchor(_ start: Int, _ len: Int) throws -> [String: Int]? {
        // Two paragraphs: "0:00 " + 10 words chars, "0:05 " + 8 chars.
        let bounds = [["start": 5, "end": 15], ["start": 20, "end": 28]]
        let value = try pure().objectForKeyedSubscript("ftAnchorAt").call(withArguments: [start, len, bounds])
        return value?.isNull == true ? nil : value?.toDictionary() as? [String: Int]
    }

    func testOlderHighlightAnchorsToItsParagraphs() throws {
        XCTAssertEqual(try anchor(7, 3), ["p": 0, "pe": 0, "ls": 2, "trim": 0])
        XCTAssertEqual(try anchor(12, 10), ["p": 0, "pe": 1, "ls": 7, "trim": 0])
        // Starts on the second timestamp: anchored at its first word, timestamp part trimmed.
        XCTAssertEqual(try anchor(17, 6), ["p": 1, "pe": 1, "ls": 0, "trim": 3])
    }

    func testAnchoredHighlightShowsOnlyOnItsVersion() throws {
        let desc: [String: Any] = ["p": 1, "pe": 2, "ls": 3, "v": "clean"]
        XCTAssertTrue(try shows(desc, ["original", "clean", "clean"]))
        XCTAssertFalse(try shows(desc, ["clean", "clean", "original"]))
        XCTAssertFalse(try shows(desc, ["clean", "clean"]))
    }

    func testOlderHighlightShowsOnlyOnAnAllOriginalPage() throws {
        let desc: [String: Any] = ["start": 40, "len": 5]
        XCTAssertTrue(try shows(desc, ["original", "original"]))
        XCTAssertFalse(try shows(desc, ["original", "clean"]))
    }
}
