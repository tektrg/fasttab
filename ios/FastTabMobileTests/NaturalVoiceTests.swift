import XCTest
@testable import FastTabMobile

// MARK: - Sentence split

final class ReadAloudSentencesTests: XCTestCase {
    func testSplitsIntoTrimmedSentencesWithChunkRanges() {
        let text = "First one. Second one?  Third!"
        let sentences = ReadAloudSentences.split(text, chunk: 3)
        XCTAssertEqual(sentences.map(\.text), ["First one.", "Second one?", "Third!"])
        XCTAssertTrue(sentences.allSatisfy { $0.chunk == 3 })
        for sentence in sentences {
            XCTAssertEqual((text as NSString).substring(with: sentence.range), sentence.text)
        }
    }

    func testUnsplittableTextIsOneSentence() {
        XCTAssertEqual(ReadAloudSentences.split("no ending here", chunk: 0).map(\.text), ["no ending here"])
        XCTAssertEqual(ReadAloudSentences.split("   ", chunk: 0), [])
    }

    func testSentencesOfChunksStartAtStartIndex() {
        let sentences = ReadAloudSentences.sentences(of: ["Title", "A. B.", "C."], from: 1)
        XCTAssertEqual(sentences.map(\.chunk), [1, 1, 2])
        XCTAssertEqual(sentences.map(\.text), ["A.", "B.", "C."])
    }
}

// MARK: - Cache

final class NaturalVoiceAudioCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("NaturalVoiceCache-\(UUID())")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func request(_ text: String, rate: Double = 1, voice: String? = nil) -> NaturalVoiceRequest {
        NaturalVoiceRequest(text: text, languageCode: "en", voice: voice, speakingRate: rate)
    }

    func testKeyDependsOnTextVoiceAndRate() {
        let base = NaturalVoiceAudioCache.key(for: request("Hello."))
        XCTAssertEqual(base, NaturalVoiceAudioCache.key(for: request("Hello.")))
        XCTAssertNotEqual(base, NaturalVoiceAudioCache.key(for: request("Hello!")))
        XCTAssertNotEqual(base, NaturalVoiceAudioCache.key(for: request("Hello.", rate: 1.25)))
        XCTAssertNotEqual(base, NaturalVoiceAudioCache.key(for: request("Hello.", voice: "en-US-x")))
        XCTAssertEqual(base.count, 64)
    }

    func testEvictsLeastRecentlyUsedOverCapacity() throws {
        let cache = NaturalVoiceAudioCache(directory: directory, capacityBytes: 25)
        let tenBytes = Data(repeating: 1, count: 10)
        cache.store(tenBytes, forKey: "a")
        try backdate("a", seconds: 30)
        cache.store(tenBytes, forKey: "b")
        try backdate("b", seconds: 20)
        _ = cache.audio(forKey: "a") // "a" is now the most recently used
        cache.store(tenBytes, forKey: "c") // 30 bytes > 25: drop the LRU, "b"
        XCTAssertNotNil(cache.audio(forKey: "a"))
        XCTAssertNil(cache.audio(forKey: "b"))
        XCTAssertNotNil(cache.audio(forKey: "c"))
    }

    private func backdate(_ key: String, seconds: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-seconds)],
            ofItemAtPath: directory.appendingPathComponent(key + ".mp3").path)
    }
}

// MARK: - Fakes

/// Scripted HTTP: answers by sentence text; records every call.
final class FakeTTSServer: @unchecked Sendable {
    struct Reply { let status: Int; let body: Data }
    private let lock = NSLock()
    private var scripted: [String: [Reply]] = [:]
    private(set) var requestedTexts: [String] = []
    /// When set, requests for this text wait until `release()`.
    var holdText: String?
    private var held: [CheckedContinuation<Void, Never>] = []

    static func audio(_ text: String) -> Data { Data("mp3:\(text)".utf8) }
    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    /// Replies in order for `text`; the last one repeats. Unscripted text → 200 audio.
    func script(_ text: String, _ replies: Reply...) { lock.withLock { scripted[text] = replies } }

    func release() { lock.withLock { held }.forEach { $0.resume() }; lock.withLock { held = [] } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let body = try JSONDecoder().decode(NaturalVoiceRequest.self, from: request.httpBody ?? Data())
        if body.text == holdText {
            await withCheckedContinuation { continuation in lock.withLock { held.append(continuation) } }
        }
        let reply: Reply = lock.withLock {
            requestedTexts.append(body.text)
            guard var replies = scripted[body.text], !replies.isEmpty else {
                return Reply(status: 200, body: Self.audio(body.text))
            }
            let next = replies.count > 1 ? replies.removeFirst() : replies[0]
            scripted[body.text] = replies
            return next
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        return (reply.body, response)
    }

    func client(cacheDirectory: URL) -> NaturalVoiceClient {
        NaturalVoiceClient(
            endpoint: URL(string: "https://api.test/v1/tts")!,
            cache: NaturalVoiceAudioCache(directory: cacheDirectory),
            headers: { ["X-Install-Id": "install-1", "Authorization": "Bearer t"] },
            send: { try await self.send($0) },
            sleep: { _ in }
        )
    }
}

/// Finishes each sentence as soon as it's played (or when released, when `holds`).
@MainActor
final class FakeAudioPlayer: NaturalVoiceAudioPlaying {
    private(set) var played: [String] = []
    var holds = false
    private var current: CheckedContinuation<Void, Error>?

    func play(_ audio: Data) async throws {
        played.append(String(decoding: audio, as: UTF8.self))
        guard holds else { return }
        try await withCheckedThrowingContinuation { current = $0 }
    }

    func finishCurrent() { current?.resume(); current = nil }
    func pause() {}
    func resume() {}
    func stop() { current?.resume(throwing: CancellationError()); current = nil }
}

/// Device-voice stand-in: records runs; tests drive its events.
@MainActor
final class FakeDeviceEngine: SpeechEngine {
    struct Run { let chunks: [String]; let from: Int; let generation: Int; let onEvent: @MainActor (Int, SpeechEngineEvent) -> Void }
    private(set) var runs: [Run] = []
    var availableVoices: [ReadAloudVoiceOption] = []
    var finishesImmediately = false

    func speak(_ chunks: [String], from startIndex: Int, voiceIdentifier: String?, rate: Double,
               generation: Int, onEvent: @escaping @MainActor (Int, SpeechEngineEvent) -> Void) {
        runs.append(Run(chunks: chunks, from: startIndex, generation: generation, onEvent: onEvent))
        if finishesImmediately {
            onEvent(generation, .word(chunk: startIndex, range: NSRange(location: 0, length: 2)))
            onEvent(generation, .chunkFinished(startIndex))
        }
    }
    func pause() {}
    func resume() {}
    func stop() {}
}

@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

// MARK: - Client error mapping

final class NaturalVoiceClientTests: XCTestCase {
    private var directory: URL!
    private let server = FakeTTSServer()

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("NaturalVoiceClient-\(UUID())")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func request(_ text: String) -> NaturalVoiceRequest {
        NaturalVoiceRequest(text: text, languageCode: "en", voice: nil, speakingRate: 1)
    }

    func testStatusMapping() {
        let quota = FakeTTSServer.json(["code": "tts_user_quota", "resetsAt": "2026-11-01T00:00:00Z", "error": ["message": "x"]])
        XCTAssertEqual(NaturalVoiceClient.error(status: 402, body: quota),
                       .quotaExhausted(resetsAt: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")))
        XCTAssertEqual(NaturalVoiceClient.error(status: 503, body: FakeTTSServer.json(["code": "tts_ceiling"])), .unavailable)
        XCTAssertEqual(NaturalVoiceClient.error(status: 503, body: FakeTTSServer.json(["code": "tts_disabled"])), .unavailable)
        XCTAssertEqual(NaturalVoiceClient.error(status: 502, body: Data()), .unavailable)
        XCTAssertEqual(NaturalVoiceClient.error(status: 400, body: FakeTTSServer.json(["code": "tts_rejected"])), .sentenceRejected)
        XCTAssertEqual(NaturalVoiceClient.error(status: 400, body: FakeTTSServer.json(["code": "bad_request"])), .unavailable)
    }

    func testSendsHeadersAndCachesSoReplaysSkipTheServer() async throws {
        final class HeaderBox: @unchecked Sendable { var headers: [String: String] = [:] }
        let seen = HeaderBox()
        let server = server
        let base = server.client(cacheDirectory: directory)
        let client = NaturalVoiceClient(endpoint: base.endpoint, cache: base.cache, headers: base.headers, send: { request in
            seen.headers = request.allHTTPHeaderFields ?? [:]
            return try await server.send(request)
        })
        var seenHeaders: [String: String] { seen.headers }
        let first = try await client.audio(for: request("Hi."))
        let second = try await client.audio(for: request("Hi."))
        XCTAssertEqual(first, FakeTTSServer.audio("Hi."))
        XCTAssertEqual(second, first)
        XCTAssertEqual(server.requestedTexts, ["Hi."])
        XCTAssertEqual(seenHeaders["X-Install-Id"], "install-1")
        XCTAssertEqual(seenHeaders["Content-Type"], "application/json")
    }

    func testRateLimitRetriesOnceThenSucceeds() async throws {
        server.script("Hi.", .init(status: 429, body: Data()), .init(status: 200, body: FakeTTSServer.audio("Hi.")))
        let audio = try await server.client(cacheDirectory: directory).audio(for: request("Hi."))
        XCTAssertEqual(audio, FakeTTSServer.audio("Hi."))
        XCTAssertEqual(server.requestedTexts.count, 2)
    }

    func testRateLimitTwiceIsUnavailable() async {
        server.script("Hi.", .init(status: 429, body: Data()))
        do {
            _ = try await server.client(cacheDirectory: directory).audio(for: request("Hi."))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NaturalVoiceError, .unavailable)
            XCTAssertEqual(server.requestedTexts.count, 2)
        }
    }

    func testNetworkFailureIsUnavailable() async {
        let base = server.client(cacheDirectory: directory)
        let offline = NaturalVoiceClient(endpoint: base.endpoint, cache: base.cache, headers: base.headers,
                                         send: { _ in throw URLError(.notConnectedToInternet) })
        do {
            _ = try await offline.audio(for: request("Hi."))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NaturalVoiceError, .unavailable)
        }
    }
}

// MARK: - Engine + fallback + controller

@MainActor
final class NaturalVoiceEngineTests: XCTestCase {
    private var directory: URL!
    private var server: FakeTTSServer!
    private var player: FakeAudioPlayer!
    private var device: FakeDeviceEngine!
    private var engine: NaturalVoiceSpeechEngine!
    private var events: [(Int, SpeechEngineEvent)] = []
    private let chunks = ["Title", "One. Two.", "Three."]

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("NaturalVoiceEngine-\(UUID())")
        server = FakeTTSServer()
        player = FakeAudioPlayer()
        device = FakeDeviceEngine()
        let natural = GoogleSpeechEngine(client: server.client(cacheDirectory: directory), player: player)
        engine = NaturalVoiceSpeechEngine(natural: natural, device: device)
        events = []
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    private func speak(from start: Int = 0, generation: Int = 1) {
        engine.speak(chunks, from: start, voiceIdentifier: nil, rate: 1, generation: generation) { [weak self] in
            self?.events.append(($0, $1))
        }
    }

    private var notices: [String] { events.compactMap { if case .notice(let m) = $0.1 { return m } else { return nil } } }

    func testPlaysEverySentenceWithSentenceHighlightsAndChunkBoundaries() async {
        speak()
        await waitUntil { self.events.contains { $0.1 == .chunkFinished(2) } }
        XCTAssertEqual(player.played, ["Title", "One.", "Two.", "Three."].map { "mp3:\($0)" })
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
        await waitUntil { self.server.requestedTexts.count == 2 }
        XCTAssertEqual(server.requestedTexts, ["One.", "Two."])
        engine.stop()
    }

    func testQuotaMidArticleFallsBackFromTheFailedSentenceWithShiftedRanges() async {
        server.script("Two.", .init(status: 402, body: FakeTTSServer.json(["code": "tts_user_quota", "resetsAt": "2026-11-01T00:00:00Z"])))
        speak(from: 1)
        await waitUntil { !self.device.runs.isEmpty }
        let run = device.runs[0]
        XCTAssertEqual(run.from, 1)
        XCTAssertEqual(run.chunks, ["Title", "Two.", "Three."]) // chunk 1 cut at the failed sentence
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].hasPrefix("Natural voice used up — resumes"))
        run.onEvent(run.generation, .word(chunk: 1, range: NSRange(location: 0, length: 3)))
        XCTAssertEqual(events.last?.1, .word(chunk: 1, range: NSRange(location: 5, length: 3)))

        // Quota remembered: the next run goes straight to the device voice.
        let requestsBefore = server.requestedTexts.count
        speak(from: 0, generation: 2)
        XCTAssertEqual(device.runs.count, 2)
        XCTAssertEqual(device.runs[1].chunks, chunks)
        XCTAssertEqual(server.requestedTexts.count, requestsBefore)
    }

    func testCeilingOrDisabledFallsBackAndRetriesNaturalNextRun() async {
        server.script("One.", .init(status: 503, body: FakeTTSServer.json(["code": "tts_disabled"])))
        speak(from: 1)
        await waitUntil { !self.device.runs.isEmpty }
        XCTAssertEqual(notices, ["Natural voice unavailable, using device voice"])
        XCTAssertEqual(device.runs[0].chunks[1], "One. Two.")
        server.script("One.", .init(status: 200, body: FakeTTSServer.audio("One.")))
        speak(from: 1, generation: 2)
        await waitUntil { self.player.played.contains("mp3:One.") }
        XCTAssertEqual(device.runs.count, 1)
    }

    func testRejectedSentenceUsesDeviceVoiceThenNaturalContinues() async {
        server.script("One.", .init(status: 400, body: FakeTTSServer.json(["code": "tts_rejected"])))
        device.finishesImmediately = true
        speak(from: 1)
        await waitUntil { self.events.contains { $0.1 == .chunkFinished(2) } }
        XCTAssertEqual(device.runs.map(\.chunks), [["One."]])
        XCTAssertEqual(player.played, ["mp3:Two.", "mp3:Three."])
        XCTAssertTrue(notices.isEmpty)
        XCTAssertTrue(events.contains { $0.1 == .word(chunk: 1, range: NSRange(location: 0, length: 2)) })
    }

    func testStoppedRunDeliversNothingLate() async {
        server.holdText = "One."
        speak(from: 1, generation: 1)
        try? await Task.sleep(for: .milliseconds(20))
        engine.stop()
        server.release()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(player.played.isEmpty)
    }

    func testControllerIgnoresAnOldRunAfterRestartWithTheNaturalEngine() async throws {
        let suite = "NaturalVoiceEngineTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = ReaderReadingSettingsStore(local: UserDefaults(suiteName: suite)!, cloud: nil, isCloudSyncEnabled: false)
        store.setNaturalVoiceEnabled(true)
        server.holdText = "One."
        let controller = ReadAloudController(engine: device, naturalEngine: { _ in self.engine },
                                             settingsStore: store, integratesWithSystem: false)
        let article = ReaderArticle(title: "Title", content: "<p>One. Two.</p><p>Three.</p>", url: URL(string: "https://e.com")!)
        controller.start(article: article, fromChunk: 1) // gen A waits on "One."
        server.holdText = nil
        controller.start(article: article, fromChunk: 2) // gen B
        await waitUntil { controller.state == .idle } // B reads "Three." to the end
        XCTAssertTrue(controller.finishedArticle)
        server.release() // A's late answer must not revive anything
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.spokenPosition)
        XCTAssertTrue(device.runs.isEmpty)
    }
}
