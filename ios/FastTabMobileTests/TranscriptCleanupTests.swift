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
        let record = TranscriptCleanupRecord(sourceDigest: TranscriptCleanupStore.digest(originals), texts: ["A.", nil])
        store.save(record, videoID: "vid_1-x")
        XCTAssertEqual(store.record(videoID: "vid_1-x", originals: originals), record)
        XCTAssertNil(store.record(videoID: "vid_1-x", originals: ["a", "changed"]))
        XCTAssertNil(store.record(videoID: "other", originals: originals))
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

    private func session(_ model: FakeModel, canClean: Bool = true, originals: [String] = ["one two", "three four"]) -> TranscriptCleanupSession {
        TranscriptCleanupSession(videoID: "vid", originals: originals, cleaner: model, canClean: canClean,
                                 store: TranscriptCleanupStore(directory: directory), defaults: defaults,
                                 isAppActive: { true })
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

    func testCloseStopsWithoutLosingProgress() async throws {
        let cleanup = session(FakeModel())
        cleanup.open()
        cleanup.close()
        XCTAssertFalse(cleanup.isCleaning)
    }
}

/// `ftTranscriptHighlightShows` in reader_template.html (FT_PURE block), run in JavaScriptCore.
final class TranscriptHighlightVersionJSTests: XCTestCase {
    private func shows(_ desc: [String: Any], _ versions: [String]) throws -> Bool {
        let url = try XCTUnwrap(Bundle(for: ReaderWebViewWarmer.self).url(forResource: "reader_template", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let begin = try XCTUnwrap(html.range(of: "// FT_PURE_BEGIN"))
        let end = try XCTUnwrap(html.range(of: "// FT_PURE_END"))
        let ctx = try XCTUnwrap(JSContext())
        ctx.evaluateScript(String(html[begin.lowerBound..<end.lowerBound]))
        return ctx.objectForKeyedSubscript("ftTranscriptHighlightShows").call(withArguments: [desc, versions]).toBool()
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
