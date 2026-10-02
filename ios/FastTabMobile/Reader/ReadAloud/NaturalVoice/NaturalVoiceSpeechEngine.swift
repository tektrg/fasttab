import Foundation

/// What Read Aloud plays when "Natural voice" is on: the natural (Google) voice, falling
/// back to the device voice so listening never just stops.
/// - quota used up / server unavailable / no network → the rest of the run continues on the
///   device voice from the failed sentence, with a `.notice`. Quota stays "used up" until
///   its reset date (later runs go straight to the device voice); other failures retry
///   the natural voice on the next run.
/// - one sentence refused by Google → only that sentence uses the device voice.
@MainActor
final class NaturalVoiceSpeechEngine: SpeechEngine {
    private let natural: GoogleSpeechEngine
    private let device: SpeechEngine
    private let now: () -> Date
    private var quotaResetsAt: Date?
    private var generation = 0
    /// Resumes a rejected sentence's wait when the device voice finished or was stopped.
    private var rejectedSentenceDone: CheckedContinuation<Void, Never>?

    init(natural: GoogleSpeechEngine, device: SpeechEngine, now: @escaping () -> Date = Date.init) {
        self.natural = natural
        self.device = device
        self.now = now
    }

    var availableVoices: [ReadAloudVoiceOption] { device.availableVoices }

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
        let deviceRun = DeviceRun(chunks: chunks, voiceIdentifier: voiceIdentifier, rate: rate,
                                  generation: generation, onEvent: onEvent)
        if let resetsAt = quotaResetsAt, now() < resetsAt {
            onEvent(generation, .notice(Self.notice(for: .quotaExhausted(resetsAt: resetsAt))))
            speakOnDevice(deviceRun, fromChunk: startIndex, offset: 0)
            return
        }
        quotaResetsAt = nil
        natural.onFailure = { [weak self] error, sentence, failedGeneration in
            guard let self, failedGeneration == self.generation else { return }
            self.fallBack(after: error, at: sentence, deviceRun)
        }
        natural.speakRejectedSentence = { [weak self] sentence, rejectedGeneration in
            guard let self, rejectedGeneration == self.generation else { return }
            await self.speakSingleSentenceOnDevice(sentence, deviceRun)
        }
        natural.speak(chunks, from: startIndex, voiceIdentifier: nil, rate: rate,
                      generation: generation, onEvent: onEvent)
    }

    // Only one of the two is ever sounding; pausing the idle one is a no-op.
    func pause() { natural.pause(); device.pause() }
    func resume() { natural.resume(); device.resume() }

    func stop() {
        natural.stop()
        device.stop()
        finishRejectedSentence()
    }

    static func notice(for error: NaturalVoiceError) -> String {
        switch error {
        case .quotaExhausted(let resetsAt?):
            return "Natural voice used up — resumes \(resetsAt.formatted(date: .abbreviated, time: .omitted))"
        case .quotaExhausted(nil):
            return "Natural voice used up — using device voice"
        case .unavailable, .sentenceRejected:
            #if DEBUG
            if let reason = NaturalVoiceDiagnostics.lastFailure {
                return "Natural voice unavailable (\(reason)), using device voice"
            }
            #endif
            return "Natural voice unavailable, using device voice"
        }
    }

    // MARK: - Device voice

    private struct DeviceRun {
        let chunks: [String]
        let voiceIdentifier: String?
        let rate: Double
        let generation: Int
        let onEvent: @MainActor (Int, SpeechEngineEvent) -> Void
    }

    private func fallBack(after error: NaturalVoiceError, at sentence: ReadAloudSentence, _ run: DeviceRun) {
        readAloudLog.info("natural voice failed (\(String(describing: error))): device voice from chunk \(sentence.chunk)")
        if case .quotaExhausted(let resetsAt) = error {
            quotaResetsAt = resetsAt ?? now().addingTimeInterval(24 * 60 * 60)
        }
        run.onEvent(run.generation, .notice(Self.notice(for: error)))
        speakOnDevice(run, fromChunk: sentence.chunk, offset: sentence.range.location)
    }

    /// Device voice from `offset` (UTF-16) inside `chunk`: that chunk is cut to start there
    /// and its event ranges are shifted back, so highlights still land on the page text.
    private func speakOnDevice(_ run: DeviceRun, fromChunk chunk: Int, offset: Int) {
        var chunks = run.chunks
        if offset > 0 { chunks[chunk] = (chunks[chunk] as NSString).substring(from: offset) }
        device.speak(chunks, from: chunk, voiceIdentifier: run.voiceIdentifier, rate: run.rate,
                     generation: run.generation) { eventGeneration, event in
            run.onEvent(eventGeneration, Self.shift(event, inChunk: chunk, by: offset))
        }
    }

    private func speakSingleSentenceOnDevice(_ sentence: ReadAloudSentence, _ run: DeviceRun) async {
        await withCheckedContinuation { continuation in
            rejectedSentenceDone = continuation
            device.speak([sentence.text], from: 0, voiceIdentifier: run.voiceIdentifier, rate: run.rate,
                         generation: run.generation) { [weak self] eventGeneration, event in
                switch event {
                case .word(_, let range):
                    let shifted = NSRange(location: range.location + sentence.range.location, length: range.length)
                    run.onEvent(eventGeneration, .word(chunk: sentence.chunk, range: shifted))
                case .chunkFinished:
                    self?.finishRejectedSentence()
                default:
                    break
                }
            }
        }
    }

    private func finishRejectedSentence() {
        rejectedSentenceDone?.resume()
        rejectedSentenceDone = nil
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
