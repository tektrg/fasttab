import Foundation

/// English voice (beta): Paradee, an 8 MB on-device model, free for everyone. Same shape as
/// the natural voice (`GoogleSpeechEngine`): one sentence at a time, the next one synthesized
/// off the main thread while the current one plays, whole-sentence highlights (`.sentence`).
///
/// Never silent: if the model can't load or a sentence fails to synthesize, the rest of the
/// run continues on the device voice from that sentence, with a `.notice`. The next run tries
/// Paradee again.
///
/// `voiceIdentifier` is a Paradee option id (`ParadeeVoice.optionID`); the device voice for a
/// fallback comes from `preferredDeviceVoice`.
@MainActor
final class ParadeeSpeechEngine: SpeechEngine {
    typealias LoadRenderer = @Sendable () async throws -> ParadeeRendering

    private let device: SpeechEngine
    private let loadRenderer: LoadRenderer
    private let player: NaturalVoiceAudioPlaying
    private let preferredDeviceVoice: @MainActor () -> String?
    private let showsTrialNotice: Bool
    private var runTask: Task<Void, Never>?
    private var pendingRenders: [Task<RenderedAudio, Error>] = []
    private var generation = 0

    init(
        device: SpeechEngine,
        loadRenderer: LoadRenderer? = nil,
        player: NaturalVoiceAudioPlaying? = nil,
        preferredDeviceVoice: @escaping @MainActor () -> String? = { nil },
        showsTrialNotice: Bool = ParadeeSpeechEngine.isDebugBuild
    ) {
        self.device = device
        self.loadRenderer = loadRenderer ?? { try await Task.detached(priority: .userInitiated) { try ParadeeRuntime.shared.renderer() }.value }
        self.player = player ?? NaturalVoiceAudioPlayer()
        self.preferredDeviceVoice = preferredDeviceVoice
        self.showsTrialNotice = showsTrialNotice
    }

    nonisolated static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    var availableVoices: [ReadAloudVoiceOption] { ParadeeVoice.allCases.map(\.option) }

    func speak(
        _ chunks: [String],
        from startIndex: Int,
        voiceIdentifier: String?,
        rate: Double,
        generation: Int,
        onEvent: @escaping @MainActor (Int, SpeechEngineEvent) -> Void
    ) {
        stop()
        self.generation = generation
        let voice = ParadeeVoice(optionID: voiceIdentifier) ?? .default
        let speed = ParadeeVoice.speed(forRate: rate)
        let sentences = ReadAloudSentences.sentences(of: chunks, from: startIndex)
        let fallback = DeviceRun(chunks: chunks, rate: rate, generation: generation, onEvent: onEvent)
        readAloudLog.debug("paradee queued \(sentences.count) sentences voice \(voice.rawValue, privacy: .public) speed \(speed) gen \(generation)")
        runTask = Task { [weak self] in
            await self?.run(sentences, voice: voice, speed: speed, fallback: fallback)
        }
    }

    // Only one of the two is ever sounding; pausing the idle one is a no-op.
    func pause() { player.pause(); device.pause() }
    func resume() { player.resume(); device.resume() }

    func stop() {
        runTask?.cancel()
        runTask = nil
        pendingRenders.forEach { $0.cancel() }
        pendingRenders = []
        player.stop()
        device.stop()
    }

    // MARK: - Run

    private func run(_ sentences: [ReadAloudSentence], voice: ParadeeVoice, speed: Float, fallback: DeviceRun) async {
        guard let first = sentences.first else { return }
        let onEvent = fallback.onEvent
        let generation = fallback.generation
        let loadStarted = Date()
        let renderer: ParadeeRendering
        do {
            renderer = try await loadRenderer()
        } catch {
            guard !Task.isCancelled else { return }
            fallBack(after: error, at: first, fallback)
            return
        }
        guard !Task.isCancelled else { return }
        var stats = ParadeeTrialStats(loadSeconds: Date().timeIntervalSince(loadStarted))
        var nextRender: Task<RenderedAudio, Error>? = render(first, renderer, voice, speed)
        for (index, sentence) in sentences.enumerated() {
            guard let currentRender = nextRender else { return }
            let isFirstOfChunk = index == 0 || sentences[index - 1].chunk != sentence.chunk
            let isLastOfChunk = index == sentences.count - 1 || sentences[index + 1].chunk != sentence.chunk
            let rendered: RenderedAudio
            do {
                rendered = try await currentRender.value
            } catch {
                guard !Task.isCancelled else { return }
                fallBack(after: error, at: sentence, fallback)
                return
            }
            guard !Task.isCancelled else { return }
            nextRender = sentences.indices.contains(index + 1) ? render(sentences[index + 1], renderer, voice, speed) : nil
            if let notice = stats.record(rendered.sentence, showsNotice: showsTrialNotice) { onEvent(generation, .notice(notice)) }
            if isFirstOfChunk { onEvent(generation, .chunkStarted(sentence.chunk)) }
            if let wav = rendered.wav { // nil: nothing speakable (e.g. only symbols), skip it
                onEvent(generation, .sentence(chunk: sentence.chunk, range: sentence.range))
                do { try await player.play(wav) } catch { return } // stopped
            }
            guard !Task.isCancelled else { return }
            if isLastOfChunk { onEvent(generation, .chunkFinished(sentence.chunk)) }
        }
    }

    private struct RenderedAudio: Sendable {
        let sentence: ParadeeRenderedSentence
        let wav: Data?
    }

    /// Synthesis and WAV encoding, both off the main thread.
    private func render(_ sentence: ReadAloudSentence, _ renderer: ParadeeRendering, _ voice: ParadeeVoice,
                        _ speed: Float) -> Task<RenderedAudio, Error> {
        let text = sentence.text
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let rendered = try renderer.render(text, voice: voice, speed: speed)
            let wav = rendered.samples.isEmpty ? nil : ParadeeWAV.encode(rendered.samples, sampleRate: rendered.sampleRate)
            return RenderedAudio(sentence: rendered, wav: wav)
        }
        pendingRenders = pendingRenders.suffix(1) + [task] // only the current + prefetched matter
        return task
    }

    // MARK: - Device voice fallback

    private struct DeviceRun {
        let chunks: [String]
        let rate: Double
        let generation: Int
        let onEvent: @MainActor (Int, SpeechEngineEvent) -> Void
    }

    static func notice(for error: Error) -> String {
        #if DEBUG
        return "English voice unavailable (\(String(describing: error))), using device voice"
        #else
        return "English voice unavailable, using device voice"
        #endif
    }

    private func fallBack(after error: Error, at sentence: ReadAloudSentence, _ run: DeviceRun) {
        guard run.generation == generation else { return }
        readAloudLog.error("paradee failed (\(String(describing: error), privacy: .public)): device voice from chunk \(sentence.chunk)")
        run.onEvent(run.generation, .notice(Self.notice(for: error)))
        // Device voice from the failed sentence: its chunk is cut to start there and event
        // ranges are shifted back, so highlights still land on the page text.
        let chunk = sentence.chunk
        let offset = sentence.range.location
        var chunks = run.chunks
        if offset > 0 { chunks[chunk] = (chunks[chunk] as NSString).substring(from: offset) }
        let voice = ReadAloudVoiceSelector.select(preferredIdentifier: preferredDeviceVoice(), languageCode: "en",
                                                  among: device.availableVoices)?.id
        device.speak(chunks, from: chunk, voiceIdentifier: voice, rate: run.rate,
                     generation: run.generation) { eventGeneration, event in
            run.onEvent(eventGeneration, Self.shift(event, inChunk: chunk, by: offset))
        }
    }

    private static func shift(_ event: SpeechEngineEvent, inChunk chunk: Int, by offset: Int) -> SpeechEngineEvent {
        func moved(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        switch event {
        case .word(chunk, let range): return .word(chunk: chunk, range: moved(range))
        case .sentence(chunk, let range): return .sentence(chunk: chunk, range: moved(range))
        default: return event
        }
    }
}

/// Trial instrumentation: every sentence's synthesis time against its audio length goes to
/// `readAloudLog`; DEBUG builds also show the average once, after the first few sentences.
struct ParadeeTrialStats {
    static let sentencesBeforeNotice = 3

    let loadSeconds: Double
    private(set) var sentences = 0
    private(set) var synthesisSeconds = 0.0
    private(set) var audioSeconds = 0.0

    init(loadSeconds: Double) { self.loadSeconds = loadSeconds }

    var averageRealTimeFactor: Double { audioSeconds > 0 ? synthesisSeconds / audioSeconds : 0 }

    /// Records one sentence; returns the one-time notice when it is due.
    mutating func record(_ audio: ParadeeRenderedSentence, showsNotice: Bool) -> String? {
        sentences += 1
        synthesisSeconds += audio.synthesisSeconds
        audioSeconds += audio.audioSeconds
        let index = sentences
        readAloudLog.info("paradee sentence \(index): \(audio.idCount) ids in \(audio.pieces) piece(s), synth \(String(format: "%.3f", audio.synthesisSeconds), privacy: .public)s, audio \(String(format: "%.2f", audio.audioSeconds), privacy: .public)s, RTF \(String(format: "%.3f", audio.realTimeFactor), privacy: .public)")
        guard sentences == Self.sentencesBeforeNotice else { return nil }
        let summary = Self.summary(averageRTF: averageRealTimeFactor, loadSeconds: loadSeconds)
        readAloudLog.info("paradee trial: \(summary, privacy: .public)")
        return showsNotice ? summary : nil
    }

    static func summary(averageRTF: Double, loadSeconds: Double) -> String {
        let speedup = averageRTF > 0 ? String(format: "%.0f× real time", 1 / averageRTF) : "n/a"
        return String(format: "Paradee RTF %.3f (%@), load %.2f s", averageRTF, speedup, loadSeconds)
    }
}

/// Float samples → 16-bit mono PCM WAV, which `NaturalVoiceAudioPlayer` (AVAudioPlayer) plays.
enum ParadeeWAV {
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)) // PCM
        append(UInt16(1)) // mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)) // byte rate
        append(UInt16(2)); append(UInt16(16)) // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        let pcm = samples.map { Int16((min(max($0, -1), 1) * Float(Int16.max)).rounded()).littleEndian }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
