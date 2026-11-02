import XCTest
@testable import FastTabMobile

// MARK: - Fakes

/// Phonemes = the text itself, so tests can feed exact phoneme strings. Records each accent.
final class FakeParadeePhonemizer: ParadeePhonemizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _accents: [ParadeeAccent] = []
    var accents: [ParadeeAccent] { lock.withLock { _accents } }

    func phonemes(for text: String, accent: ParadeeAccent) -> String {
        lock.withLock { _accents.append(accent) }
        return text
    }
}

/// Records every model call; returns one sample per input id.
final class FakeParadeeModel: ParadeeWaveformModel, @unchecked Sendable {
    struct Call: Equatable { let ids: [Int64]; let voiceIndex: Int64; let speed: Float }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    func waveform(ids: [Int64], voiceIndex: Int64, speed: Float) throws -> [Float] {
        lock.withLock { _calls.append(Call(ids: ids, voiceIndex: voiceIndex, speed: speed)) }
        return Array(repeating: 0.5, count: ids.count)
    }
}

/// Sentence-level stand-in for the whole synthesis pipeline.
final class FakeParadeeRenderer: ParadeeRendering, @unchecked Sendable {
    private let lock = NSLock()
    private var _rendered: [String] = []
    private var _voices: [ParadeeVoice] = []
    var rendered: [String] { lock.withLock { _rendered } }
    var voices: [ParadeeVoice] { lock.withLock { _voices } }
    var failing: Set<String> = []
    /// Text that renders to no audio (nothing speakable).
    var silent: Set<String> = []

    func render(_ text: String, voice: ParadeeVoice, speed: Float) throws -> ParadeeRenderedSentence {
        lock.withLock { _rendered.append(text); _voices.append(voice) }
        if failing.contains(text) { throw ParadeeError.inferenceFailed("scripted") }
        let samples: [Float] = silent.contains(text) ? [] : Array(repeating: 0.1, count: 2_400)
        return ParadeeRenderedSentence(samples: samples, sampleRate: 24_000, idCount: text.count, pieces: 1,
                                       synthesisSeconds: 0.01)
    }
}

private func bundledConfig() throws -> ParadeeConfig {
    let url = try XCTUnwrap(Bundle.main.url(forResource: ParadeeRuntime.configResource, withExtension: "json"),
                            "paradee_config.json is an app resource")
    return try JSONDecoder().decode(ParadeeConfig.self, from: Data(contentsOf: url))
}

// MARK: - Token ids

final class ParadeeTokenizerTests: XCTestCase {
    func testBundledConfigMatchesTheModelCard() throws {
        let config = try bundledConfig()
        XCTAssertEqual(config.sampleRate, 24_000)
        XCTAssertEqual(config.voices, ["af_heart", "bf_isabella", "am_puck", "bm_fable"])
        XCTAssertEqual(ParadeeVoice.allCases.map { config.index(of: $0) }, [0, 2, 1, 3])
        XCTAssertNotNil(Bundle.main.path(forResource: ParadeeRuntime.modelResource, ofType: "onnx"))
    }

    /// The same ids the reference Python (`paradee/tts.py`) feeds the model for this string.
    func testIdsMatchThePythonReference() throws {
        let tokenizer = ParadeeTokenizer(vocab: try bundledConfig().vocab)
        let phonemes = "ðə lˈIbɹəɹi ˈOpənz æt nˈIn, bˌʌt ðə kˈɔfi ʃˈɑp nˈɛkst dˈɔɹ ɪz jˈuʒəwəli bˈɪzi bI ˈAt."
        let python: [Int64] = [0, 81, 83, 16, 54, 156, 25, 44, 123, 83, 123, 51, 16, 156, 31, 58, 83, 56, 68, 16, 72, 62,
                               16, 56, 156, 25, 56, 3, 16, 44, 157, 138, 62, 16, 81, 83, 16, 53, 156, 76, 48, 51, 16, 131,
                               156, 69, 58, 16, 56, 156, 86, 53, 61, 62, 16, 46, 156, 76, 123, 16, 102, 68, 16, 52, 156, 63,
                               147, 83, 65, 83, 54, 51, 16, 44, 156, 102, 68, 51, 16, 44, 25, 16, 156, 24, 62, 4, 0]
        XCTAssertEqual(ParadeeTokenizer.padded(tokenizer.ids(for: phonemes)), python)
    }

    func testOneIdPerScalarUnknownDroppedCombiningMarkKept() {
        let tokenizer = ParadeeTokenizer(vocab: ["a": 43, "̃": 17, " ": 16])
        // "ã" as a + combining tilde is one Character but two scalars → two ids; "#" is unknown.
        XCTAssertEqual(tokenizer.ids(for: "a\u{0303} #a"), [43, 17, 16, 43])
        XCTAssertEqual(ParadeeTokenizer.padded([43]), [0, 43, 0])
    }

    private let small = ParadeeTokenizer(vocab: ["a": 1, "b": 2, ",": 3, " ": 16])

    func testShortSentenceIsOnePiece() {
        XCTAssertEqual(small.pieces(of: [1, 16, 2], maxIDs: 10), [[1, 16, 2]])
        XCTAssertEqual(small.pieces(of: [16, 1, 16], maxIDs: 10), [[1]])
        XCTAssertEqual(small.pieces(of: [], maxIDs: 10), [])
    }

    func testLongSentenceSplitsAtWordBoundariesWithinTheLimit() {
        let word: [Int64] = [1, 2, 1]
        let ids = Array(Array(repeating: word + [16], count: 300).joined()) // 1,200 ids, 300 words
        let pieces = small.pieces(of: ids)
        XCTAssertGreaterThan(pieces.count, 1)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, ParadeeTokenizer.maxIDs)
            XCTAssertLessThanOrEqual(ParadeeTokenizer.padded(piece).count, 512)
            XCTAssertNotEqual(piece.first, 16)
            XCTAssertNotEqual(piece.last, 16)
            XCTAssertEqual(piece.count % 4, 3, "whole words only")
        }
        // Nothing lost but the spaces at the cuts.
        XCTAssertEqual(pieces.flatMap { $0 }.filter { $0 != 16 }.count, 900)
    }

    func testPrefersAClauseEndInTheSecondHalf() {
        // a a a a a , b b b b  — cut after "," rather than at the last space that fits.
        let ids: [Int64] = [1, 16, 1, 16, 1, 16, 1, 16, 1, 3, 16, 2, 16, 2, 16, 2, 16, 2]
        XCTAssertEqual(small.pieces(of: ids, maxIDs: 14), [[1, 16, 1, 16, 1, 16, 1, 16, 1, 3], [2, 16, 2, 16, 2, 16, 2]])
    }

    func testAWordLongerThanTheLimitIsTheOnlyHardCut() {
        let pieces = small.pieces(of: Array(repeating: 1, count: 25), maxIDs: 10)
        XCTAssertEqual(pieces.map(\.count), [10, 10, 5])
    }
}

// MARK: - Renderer, gate, speed, WAV

final class ParadeeRendererTests: XCTestCase {
    func testPadsEachPieceUsesTheConfigVoiceIndexAndTheVoiceAccent() throws {
        let config = try bundledConfig()
        let phonemizer = FakeParadeePhonemizer()
        let model = FakeParadeeModel()
        let renderer = ParadeeRenderer(phonemizer: phonemizer, tokenizer: ParadeeTokenizer(vocab: config.vocab),
                                       model: model, config: config)
        let long = Array(repeating: "ab", count: 200).joined(separator: " ") // 599 ids
        let audio = try renderer.render(long, voice: .fable, speed: 1.25)
        XCTAssertEqual(phonemizer.accents, [.british])
        XCTAssertEqual(model.calls.count, 2)
        for call in model.calls {
            XCTAssertEqual(call.ids.first, 0)
            XCTAssertEqual(call.ids.last, 0)
            XCTAssertLessThanOrEqual(call.ids.count, 512)
            XCTAssertEqual(call.voiceIndex, 3)
            XCTAssertEqual(call.speed, 1.25)
        }
        XCTAssertEqual(audio.idCount, 599)
        XCTAssertEqual(audio.pieces, 2)
        XCTAssertEqual(audio.samples.count, model.calls.map(\.ids.count).reduce(0, +))
        _ = try renderer.render("ab", voice: .puck, speed: 1)
        XCTAssertEqual(phonemizer.accents.last, .american)
        XCTAssertEqual(model.calls.last?.voiceIndex, 2)
    }

    func testGateOnByDefaultOnlyWhereOfferedAndOnlyForEnglish() {
        XCTAssertTrue(ParadeeGate.isEnabled(setting: nil, offered: true))
        XCTAssertFalse(ParadeeGate.isEnabled(setting: nil, offered: false), "App Store build: off")
        XCTAssertFalse(ParadeeGate.isEnabled(setting: true, offered: false))
        XCTAssertFalse(ParadeeGate.isEnabled(setting: false, offered: true))
        XCTAssertTrue(ParadeeGate.routesToParadee(languageCode: "en", setting: nil, offered: true))
        XCTAssertTrue(ParadeeGate.routesToParadee(languageCode: "en-GB", setting: true, offered: true))
        XCTAssertFalse(ParadeeGate.routesToParadee(languageCode: "vi", setting: true, offered: true))
        XCTAssertFalse(ParadeeGate.routesToParadee(languageCode: nil, setting: true, offered: true))
        XCTAssertFalse(ParadeeGate.routesToParadee(languageCode: "en", setting: false, offered: true))
    }

    func testVoicesSpeedAndOptionIds() {
        XCTAssertEqual(ParadeeVoice.resolve(nil), .heart)
        XCTAssertEqual(ParadeeVoice.resolve("bf_isabella"), .isabella)
        XCTAssertEqual(ParadeeVoice.resolve("com.apple.voice.x"), .heart)
        XCTAssertEqual(ParadeeVoice(optionID: ParadeeVoice.puck.optionID), .puck)
        XCTAssertNil(ParadeeVoice(optionID: "af_heart"))
        XCTAssertEqual(ParadeeVoice.isabella.accent, .british)
        XCTAssertEqual(ParadeeVoice.puck.accent, .american)
        XCTAssertEqual(ParadeeVoice.speed(forRate: 1), 1)
        XCTAssertEqual(ParadeeVoice.speed(forRate: 0.75), 0.75)
        XCTAssertEqual(ParadeeVoice.speed(forRate: 3), 2)
        XCTAssertEqual(ParadeeVoice.speed(forRate: 0.1), 0.5)
    }

    func testWAVIsSixteenBitMonoAtTheModelRate() {
        let wav = ParadeeWAV.encode([0, 1, -1, 2], sampleRate: 24_000)
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        func u32(_ at: Int) -> UInt32 { wav.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func i16(_ at: Int) -> Int16 { wav.subdata(in: at..<at + 2).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) } }
        XCTAssertEqual(u32(24), 24_000)
        XCTAssertEqual(u32(40), 8)
        XCTAssertEqual([i16(44), i16(46), i16(48), i16(50)], [0, Int16.max, -Int16.max, Int16.max])
    }
}

// MARK: - Engine + fallback + routing

@MainActor
final class ParadeeSpeechEngineTests: XCTestCase {
    private var renderer: FakeParadeeRenderer!
    private var player: FakeAudioPlayer!
    private var device: FakeDeviceEngine!
    private var engine: ParadeeSpeechEngine!
    private var events: [(Int, SpeechEngineEvent)] = []
    private let chunks = ["Title", "One. Two.", "Three."]

    override func setUp() async throws {
        renderer = FakeParadeeRenderer()
        player = FakeAudioPlayer()
        device = FakeDeviceEngine()
        engine = makeEngine(load: { [renderer] in renderer! })
        events = []
    }

    private func makeEngine(load: @escaping ParadeeSpeechEngine.LoadRenderer, notice: Bool = false) -> ParadeeSpeechEngine {
        ParadeeSpeechEngine(device: device, loadRenderer: load, player: player,
                            preferredDeviceVoice: { nil }, showsTrialNotice: notice)
    }

    private func speak(from start: Int = 0, voice: ParadeeVoice = .heart, generation: Int = 1) {
        engine.speak(chunks, from: start, voiceIdentifier: voice.optionID, rate: 1, generation: generation) { [weak self] in
            self?.events.append(($0, $1))
        }
    }

    private var notices: [String] { events.compactMap { if case .notice(let m) = $0.1 { return m } else { return nil } } }

    func testPlaysEverySentenceWithSentenceHighlightsAndChunkBoundaries() async {
        speak(voice: .isabella)
        await waitUntil { self.events.contains { $0.1 == .chunkFinished(2) } }
        XCTAssertEqual(renderer.rendered, ["Title", "One.", "Two.", "Three."])
        XCTAssertEqual(Set(renderer.voices), [.isabella])
        XCTAssertEqual(player.played.count, 4)
        XCTAssertEqual(events.map(\.1), [
            .chunkStarted(0), .sentence(chunk: 0, range: NSRange(location: 0, length: 5)), .chunkFinished(0),
            .chunkStarted(1), .sentence(chunk: 1, range: NSRange(location: 0, length: 4)),
            .sentence(chunk: 1, range: NSRange(location: 5, length: 4)), .chunkFinished(1),
            .chunkStarted(2), .sentence(chunk: 2, range: NSRange(location: 0, length: 6)), .chunkFinished(2),
        ])
        XCTAssertTrue(device.runs.isEmpty)
    }

    func testPrefetchesTheNextSentenceWhileOnePlays() async {
        player.holds = true
        speak(from: 1)
        await waitUntil { self.player.played.count == 1 }
        await waitUntil { self.renderer.rendered.count == 2 }
        XCTAssertEqual(renderer.rendered, ["One.", "Two."])
        engine.stop()
    }

    func testSynthesisFailureFallsBackFromTheFailedSentenceWithShiftedRanges() async {
        renderer.failing = ["Two."]
        speak(from: 1)
        await waitUntil { !self.device.runs.isEmpty }
        let run = device.runs[0]
        XCTAssertEqual(run.from, 1)
        XCTAssertEqual(run.chunks, ["Title", "Two.", "Three."]) // chunk 1 cut at the failed sentence
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].hasPrefix("English voice unavailable"))
        XCTAssertEqual(player.played.count, 1, "One. played before the failure")
        run.onEvent(run.generation, .word(chunk: 1, range: NSRange(location: 0, length: 3)))
        XCTAssertEqual(events.last?.1, .word(chunk: 1, range: NSRange(location: 5, length: 3)))
    }

    func testModelThatFailsToLoadFallsBackToTheDeviceVoiceForTheWholeRun() async {
        engine = makeEngine(load: { throw ParadeeError.modelUnavailable("missing") })
        speak(from: 1)
        await waitUntil { !self.device.runs.isEmpty }
        XCTAssertEqual(device.runs[0].chunks, chunks)
        XCTAssertEqual(device.runs[0].from, 1)
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(player.played.isEmpty)
    }

    func testSilentSentenceIsSkippedNotHighlighted() async {
        renderer.silent = ["Two."]
        speak(from: 1)
        await waitUntil { self.events.contains { $0.1 == .chunkFinished(2) } }
        XCTAssertEqual(player.played.count, 2)
        XCTAssertFalse(events.contains { $0.1 == .sentence(chunk: 1, range: NSRange(location: 5, length: 4)) })
        XCTAssertTrue(device.runs.isEmpty)
    }

    func testStoppedRunDeliversNothingLate() async {
        player.holds = true
        speak(from: 1)
        await waitUntil { self.player.played.count == 1 }
        engine.stop()
        let count = events.count
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(events.count, count)
        XCTAssertEqual(player.played.count, 1)
    }

    func testTrialNoticeShowsTheAverageRealTimeFactorOnceAfterThreeSentences() async {
        engine = makeEngine(load: { [renderer] in renderer! }, notice: true)
        speak()
        await waitUntil { self.events.contains { $0.1 == .chunkFinished(2) } }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].hasPrefix("Paradee RTF 0.100"), notices[0]) // 0.01 s per 0.1 s of audio
    }

    // MARK: Routing in the controller

    private let english = ReaderArticle(
        title: "A walk in the park",
        content: "<p>The library opens at nine, but the coffee shop next door is usually busy by eight.</p><p>Turn left at the second light, then keep going until you see the bakery.</p>",
        url: URL(string: "https://e.com")!)
    private let vietnamese = ReaderArticle(
        title: "Một ngày đẹp trời",
        content: "<p>Hôm nay trời rất đẹp và chúng tôi đi dạo trong công viên gần nhà.</p><p>Buổi chiều chúng tôi uống cà phê ở quán bên cạnh thư viện.</p>",
        url: URL(string: "https://e.com")!)

    private func controller(offered: Bool, configure: (ReaderReadingSettingsStore) -> Void = { _ in })
        -> (ReadAloudController, String) {
        let suite = "ParadeeSpeechEngineTests.\(UUID().uuidString)"
        let store = ReaderReadingSettingsStore(local: UserDefaults(suiteName: suite)!, cloud: nil, isCloudSyncEnabled: false)
        configure(store)
        let controller = ReadAloudController(engine: device, paradeeEngine: { _ in self.engine },
                                             settingsStore: store, integratesWithSystem: false,
                                             isNaturalVoiceEntitled: { false }, isParadeeOffered: { offered })
        return (controller, suite)
    }

    func testEnglishArticleReadsWithTheChosenParadeeVoiceWhenOffered() async {
        let (controller, suite) = controller(offered: true) { $0.setParadeeVoice(.puck) }
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        controller.start(article: english)
        await waitUntil { !self.renderer.rendered.isEmpty }
        XCTAssertEqual(renderer.voices.first, .puck)
        XCTAssertTrue(device.runs.isEmpty)
        controller.stop()
    }

    func testEnglishArticleUsesTheDeviceVoiceWhenSwitchedOffOrNotOffered() async {
        for (offered, setting) in [(true, false), (false, true)] {
            let (controller, suite) = controller(offered: offered) { $0.setParadeeVoiceEnabled(setting) }
            controller.start(article: english)
            controller.stop()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(device.runs.count, 2)
        XCTAssertTrue(renderer.rendered.isEmpty)
    }

    func testNonEnglishArticleIsUntouched() async {
        let (controller, suite) = controller(offered: true)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        controller.start(article: vietnamese)
        XCTAssertEqual(device.runs.count, 1)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(renderer.rendered.isEmpty)
        controller.stop()
    }
}
