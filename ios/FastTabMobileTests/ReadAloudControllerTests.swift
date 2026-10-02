import XCTest
@testable import FastTabMobile

/// Read Aloud state machine against a fake engine that delivers late / stale callbacks,
/// the failure modes behind "speech stops midway" and "two frozen highlights".
@MainActor
final class ReadAloudControllerTests: XCTestCase {

    private final class FakeSpeechEngine: SpeechEngine {
        struct Run { let from: Int; let generation: Int; let onEvent: @MainActor (Int, SpeechEngineEvent) -> Void }
        var runs: [Run] = []
        var stopCount = 0
        var availableVoices: [ReadAloudVoiceOption] = []

        func speak(_ chunks: [String], from startIndex: Int, voiceIdentifier: String?, rate: Double,
                   generation: Int, onEvent: @escaping @MainActor (Int, SpeechEngineEvent) -> Void) {
            runs.append(Run(from: startIndex, generation: generation, onEvent: onEvent))
        }
        func pause() {}
        func resume() {}
        func stop() { stopCount += 1 }

        /// Sends an event as if from run `index` (default: latest).
        func send(_ event: SpeechEngineEvent, run index: Int? = nil) {
            let run = runs[index ?? runs.count - 1]
            run.onEvent(run.generation, event)
        }
    }

    private var engine: FakeSpeechEngine!
    private var controller: ReadAloudController!
    private var suiteName: String!
    private var store: ReaderReadingSettingsStore!

    override func setUp() async throws {
        suiteName = "ReadAloudControllerTests.\(UUID().uuidString)"
        store = ReaderReadingSettingsStore(local: UserDefaults(suiteName: suiteName)!, cloud: nil, isCloudSyncEnabled: false)
        engine = FakeSpeechEngine()
        controller = ReadAloudController(engine: engine, settingsStore: store, integratesWithSystem: false)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private let article = ReaderArticle(
        title: "Title", content: "<p>One two.</p><p>Three four.</p>", url: URL(string: "https://e.com")!)

    private func word(_ chunk: Int, _ location: Int) -> SpeechEngineEvent {
        .word(chunk: chunk, range: NSRange(location: location, length: 3))
    }

    func testAllChunksQueuedInOneRunSoTheSynthesizerNeverIdles() {
        controller.start(article: article)
        XCTAssertEqual(engine.runs.count, 1)
        XCTAssertEqual(engine.runs[0].from, 0)
        XCTAssertEqual(controller.chunks, ["Title", "One two.", "Three four."])
    }

    func testFinishOfAMiddleChunkDoesNotStopPlayback() {
        controller.start(article: article)
        engine.send(.chunkStarted(0)); engine.send(.chunkFinished(0))
        engine.send(.chunkStarted(1)); engine.send(.chunkFinished(1))
        XCTAssertEqual(controller.state, .playing)
        engine.send(.chunkStarted(2)); engine.send(.chunkFinished(2))
        XCTAssertEqual(controller.state, .idle)
    }

    func testLateWordFromPreviousChunkIsIgnored() {
        controller.start(article: article)
        engine.send(.chunkStarted(1))
        engine.send(word(1, 0))
        engine.send(word(0, 2)) // arrives after chunk 1 started
        XCTAssertEqual(controller.spokenPosition?.chunkIndex, 1)
        XCTAssertEqual(controller.spokenPosition?.wordRange.location, 0)
    }

    func testCallbacksFromAStoppedRunCannotReviveOrStopTheNewOne() {
        controller.start(article: article)
        controller.start(article: article) // restart: run 0 is stale
        engine.send(.chunkStarted(2), run: 0)
        engine.send(.chunkFinished(2), run: 0) // stale "last chunk finished"
        XCTAssertEqual(controller.state, .playing)
        engine.send(word(0, 0), run: 0)
        XCTAssertNil(controller.spokenPosition)

        controller.stop()
        engine.send(.chunkStarted(0))
        engine.send(word(0, 0))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.spokenPosition)
    }

    func testPauseClearsHighlightAndIgnoresWordsUntilResume() {
        controller.start(article: article)
        engine.send(.chunkStarted(0)); engine.send(word(0, 0))
        controller.pause()
        XCTAssertNil(controller.spokenPosition)
        engine.send(word(0, 2))
        XCTAssertNil(controller.spokenPosition)
        controller.resume()
        engine.send(word(0, 2))
        XCTAssertEqual(controller.spokenPosition?.wordRange.location, 2)
    }

    func testSpeedChangeRestartsCurrentChunkUnderNewSession() {
        controller.start(article: article)
        engine.send(.chunkStarted(1)); engine.send(word(1, 0))
        let oldSession = controller.spokenPosition?.sessionID
        store.setSpeechRate(1.5)
        XCTAssertEqual(engine.runs.count, 2)
        XCTAssertEqual(engine.runs[1].from, 1)
        XCTAssertNil(controller.spokenPosition)
        engine.send(word(1, 4), run: 0) // old run's late word
        XCTAssertNil(controller.spokenPosition)
        engine.send(.chunkStarted(1)); engine.send(word(1, 4))
        XCTAssertNotEqual(controller.spokenPosition?.sessionID, oldSession)
    }

    // MARK: - Tap on the article

    /// Page text for `article` as the page's text map builds it (title + body, no separators).
    private let pageText = "TitleOne two.Three four."

    func testTapDoesNothingUntilReadAloudWasUsed() {
        controller.handleTap(pageText: pageText, offset: 15, article: article)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(engine.runs.isEmpty)
    }

    func testTapAnywhereWhilePlayingPauses() {
        controller.start(article: article)
        engine.send(.chunkStarted(0)); engine.send(word(0, 0))
        controller.handleTap(pageText: pageText, offset: 15, article: article) // on another paragraph
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(engine.runs.count, 1) // paused, no jump
        XCTAssertNil(controller.spokenPosition)
        XCTAssertEqual(controller.tapFeedback?.kind, .paused)

        controller.resume()
        controller.handleTap(pageText: pageText, offset: -1, article: article) // margin
        XCTAssertEqual(controller.state, .paused)
    }

    func testTapWhilePausedOnPausedParagraphOrOffTextResumes() {
        controller.start(article: article)
        engine.send(.chunkStarted(1))
        controller.pause()
        controller.handleTap(pageText: pageText, offset: 6, article: article) // "One two." = paused chunk
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(engine.runs.count, 1) // resumed, not restarted
        XCTAssertEqual(controller.tapFeedback?.kind, .playing)

        controller.pause()
        controller.handleTap(pageText: pageText, offset: -1, article: article)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(engine.runs.count, 1)
    }

    func testTapWhilePausedOnAnotherParagraphReadsFromThereUnderNewRun() {
        controller.start(article: article)
        engine.send(.chunkStarted(0)); engine.send(word(0, 0))
        controller.pause()
        controller.isAutoScrollPaused = true
        controller.handleTap(pageText: pageText, offset: 15, article: article) // "Three four."
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(engine.runs.count, 2)
        XCTAssertEqual(engine.runs[1].from, 2)
        XCTAssertFalse(controller.isAutoScrollPaused)
        engine.send(word(0, 2), run: 0) // late word from the old run
        XCTAssertNil(controller.spokenPosition)
        engine.send(.chunkStarted(2)); engine.send(word(2, 0))
        XCTAssertEqual(controller.spokenPosition?.chunkIndex, 2)
    }

    func testTapWhenStoppedReadsFromTappedParagraph() {
        controller.start(article: article)
        controller.stop()
        controller.handleTap(pageText: pageText, offset: 15, article: article)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(engine.runs.last?.from, 2)
    }

    // MARK: - Play starts from the reading position

    private func viewport(first: Int, last: Int, atTop: Bool = false) -> ReadAloudViewport {
        ReadAloudViewport(pageText: pageText, firstVisibleOffset: first, lastVisibleOffset: last, isAtTop: atTop)
    }

    func testPlayAtTopOfArticleStartsWithTitle() {
        controller.play(article: article, viewport: viewport(first: 0, last: 23, atTop: true))
        XCTAssertEqual(engine.runs.last?.from, 0)
    }

    func testPlayScrolledDownStartsAtFirstParagraphOnScreen() {
        controller.play(article: article, viewport: viewport(first: 9, last: 23)) // mid "One two."
        XCTAssertEqual(engine.runs.last?.from, 1)
        controller.stop()
        controller.play(article: article, viewport: viewport(first: 13, last: 23))
        XCTAssertEqual(engine.runs.last?.from, 2)
    }

    func testPlayAfterPauseResumesWhilePausedParagraphIsOnScreen() {
        controller.play(article: article, viewport: viewport(first: 5, last: 23))
        engine.send(.chunkStarted(1))
        controller.pause()
        controller.play(article: article, viewport: viewport(first: 10, last: 23)) // still shows chunk 1
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(engine.runs.count, 1) // resumed, not restarted
    }

    func testPlayAfterPauseStartsAtScreenWhenPausedParagraphScrolledAway() {
        controller.play(article: article, viewport: viewport(first: 0, last: 23, atTop: true))
        engine.send(.chunkStarted(0))
        controller.pause()
        controller.play(article: article, viewport: viewport(first: 14, last: 23)) // title off screen
        XCTAssertEqual(engine.runs.count, 2)
        XCTAssertEqual(engine.runs.last?.from, 2)
        XCTAssertEqual(controller.state, .playing)
    }

    func testPlayAfterReachingTheEndRestartsFromTitle() {
        controller.play(article: article, viewport: viewport(first: 13, last: 23))
        engine.send(.chunkStarted(2)); engine.send(.chunkFinished(2))
        XCTAssertEqual(controller.state, .idle)
        controller.play(article: article, viewport: viewport(first: 13, last: 23))
        XCTAssertEqual(engine.runs.last?.from, 0)
    }

    func testPlayWithoutPageInfoStartsFromTitleOrResumes() {
        controller.play(article: article, viewport: nil)
        XCTAssertEqual(engine.runs.last?.from, 0)
        controller.pause()
        controller.play(article: article, viewport: nil)
        XCTAssertEqual(engine.runs.count, 1)
        XCTAssertEqual(controller.state, .playing)
    }

    func testTapWhenStoppedOffAnyParagraphDoesNothing() {
        controller.start(article: article)
        controller.stop()
        controller.handleTap(pageText: pageText + "code", offset: 25, article: article) // code block
        controller.handleTap(pageText: pageText, offset: -1, article: article)          // margin
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(engine.runs.count, 1)
        XCTAssertNil(controller.tapFeedback)
    }
}
