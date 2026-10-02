import AVFoundation

/// Seam between Read Aloud and whatever produces the audio. Today only the free
/// on-device engine exists; a paid cloud "natural voice" engine can conform later
/// without touching `ReadAloudController`.
@MainActor
protocol SpeechEngine: AnyObject {
    /// Voices this engine can speak with (shown in the voice picker).
    var availableVoices: [ReadAloudVoiceOption] { get }
    /// Speaks one chunk; `completion` fires once it finishes naturally (not after `stop`).
    func speak(_ text: String, voiceIdentifier: String?, rate: Double, completion: @escaping @MainActor () -> Void)
    func pause()
    func resume()
    func stop()
}

/// Free tier: Apple's on-device `AVSpeechSynthesizer`.
@MainActor
final class AppleSpeechEngine: NSObject, SpeechEngine {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (@MainActor () -> Void)?

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

    func speak(_ text: String, voiceIdentifier: String?, rate: Double, completion: @escaping @MainActor () -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        if let voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        }
        utterance.rate = Self.utteranceRate(forMultiplier: rate)
        utterance.postUtteranceDelay = 0.25 // a breath between paragraphs
        self.completion = completion
        synthesizer.speak(utterance)
    }

    func pause() { synthesizer.pauseSpeaking(at: .word) }
    func resume() { synthesizer.continueSpeaking() }

    func stop() {
        completion = nil
        synthesizer.stopSpeaking(at: .immediate)
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

    fileprivate func utteranceDidFinish() {
        let finished = completion
        completion = nil
        finished?()
    }
}

extension AppleSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceDidFinish() }
    }
}
