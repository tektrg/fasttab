import AVFoundation
import os

let readAloudLog = Logger(subsystem: "app.theindie.FastTabMobile", category: "ReadAloud")

/// Progress from a `SpeechEngine`. Every event names the chunk it belongs to, so a
/// late callback from an earlier chunk can never be mistaken for the current one.
enum SpeechEngineEvent: Equatable {
    case chunkStarted(Int)
    /// UTF-16 range, within the chunk, of the word about to be spoken.
    case word(chunk: Int, range: NSRange)
    case chunkFinished(Int)
}

/// Seam between Read Aloud and whatever produces the audio. Today only the free
/// on-device engine exists; a paid cloud "natural voice" engine can conform later
/// (e.g. emitting `.word` from timestamps) without touching `ReadAloudController`.
@MainActor
protocol SpeechEngine: AnyObject {
    /// Voices this engine can speak with (shown in the voice picker).
    var availableVoices: [ReadAloudVoiceOption] { get }
    /// Queues `chunks[startIndex...]` back to back. Events are delivered on the main
    /// actor in order, tagged with `generation`; `stop` ends a generation.
    func speak(
        _ chunks: [String],
        from startIndex: Int,
        voiceIdentifier: String?,
        rate: Double,
        generation: Int,
        onEvent: @escaping @MainActor (_ generation: Int, SpeechEngineEvent) -> Void
    )
    func pause()
    func resume()
    func stop()
}

/// Free tier: Apple's on-device `AVSpeechSynthesizer`.
///
/// All chunks are queued at once so the synthesizer never idles between paragraphs:
/// an idle gap lets iOS suspend a backgrounded app, which silently ended playback.
@MainActor
final class AppleSpeechEngine: NSObject, SpeechEngine {
    private struct UtteranceTag { let generation: Int; let chunk: Int }

    private let synthesizer = AVSpeechSynthesizer()
    private var tags: [ObjectIdentifier: UtteranceTag] = [:]
    private var onEvent: (@MainActor (Int, SpeechEngineEvent) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        // ReadAloudController owns the session (background playback + Now Playing).
        synthesizer.usesApplicationAudioSession = true
    }

    var availableVoices: [ReadAloudVoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            ReadAloudVoiceOption(
                id: voice.identifier,
                name: voice.name,
                languageCode: voice.language,
                quality: Self.quality(of: voice)
            )
        }
    }

    func speak(
        _ chunks: [String],
        from startIndex: Int,
        voiceIdentifier: String?,
        rate: Double,
        generation: Int,
        onEvent: @escaping @MainActor (Int, SpeechEngineEvent) -> Void
    ) {
        self.onEvent = onEvent
        let voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        for chunk in chunks.indices where chunk >= startIndex {
            let utterance = AVSpeechUtterance(string: chunks[chunk])
            utterance.voice = voice
            utterance.rate = Self.utteranceRate(forMultiplier: rate)
            utterance.postUtteranceDelay = 0.25 // a breath between paragraphs
            tags[ObjectIdentifier(utterance)] = UtteranceTag(generation: generation, chunk: chunk)
            synthesizer.speak(utterance)
        }
        readAloudLog.debug("engine queued chunks \(startIndex)..<\(chunks.count) gen \(generation)")
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        tags = [:] // late callbacks for the cancelled queue now resolve to nothing
    }

    /// Maps the user-facing multiplier (1.0 = normal) onto AVSpeech's 0–1 scale.
    static func utteranceRate(forMultiplier multiplier: Double) -> Float {
        let rate = AVSpeechUtteranceDefaultSpeechRate * Float(multiplier)
        return min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    private static func quality(of voice: AVSpeechSynthesisVoice) -> ReadAloudVoiceOption.Quality {
        switch voice.quality {
        case .premium: return .premium
        case .enhanced: return .enhanced
        default: return .standard
        }
    }

    /// Delegate callbacks funnel through here. `DispatchQueue.main.async` keeps them in
    /// the order AVFoundation sent them (unlike separate `Task`s, which may reorder).
    fileprivate nonisolated func deliver(
        _ utterance: AVSpeechUtterance,
        isFinal: Bool,
        _ makeEvent: @escaping @Sendable (Int) -> SpeechEngineEvent?
    ) {
        let key = ObjectIdentifier(utterance)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let tag = self.tags[key] else { return }
                if isFinal { self.tags[key] = nil }
                if let event = makeEvent(tag.chunk) { self.onEvent?(tag.generation, event) }
            }
        }
    }
}

extension AppleSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        deliver(utterance, isFinal: false) { .chunkStarted($0) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        deliver(utterance, isFinal: false) { .word(chunk: $0, range: characterRange) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        deliver(utterance, isFinal: true) { .chunkFinished($0) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        deliver(utterance, isFinal: true) { _ in nil }
    }
}
