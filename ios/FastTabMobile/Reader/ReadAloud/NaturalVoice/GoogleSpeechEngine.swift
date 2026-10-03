import Foundation

/// Natural voice: Google TTS audio via theindie-api, one request per sentence, the next
/// sentence prefetched while the current one plays so there is no gap. Highlights whole
/// sentences (`.sentence`), not words. Errors are not spoken around here: they go to
/// `onFailure` / `speakRejectedSentence`, which `NaturalVoiceSpeechEngine` wires to the
/// device voice.
@MainActor
final class GoogleSpeechEngine: SpeechEngine {
    /// The run can't continue with the natural voice from `sentence` on.
    var onFailure: (@MainActor (_ error: NaturalVoiceError, _ sentence: ReadAloudSentence, _ generation: Int) -> Void)?
    /// Speaks one sentence the server refused (some other way); returns when done.
    var speakRejectedSentence: (@MainActor (_ sentence: ReadAloudSentence, _ generation: Int) async -> Void)?

    private let client: NaturalVoiceClient
    private let player: NaturalVoiceAudioPlaying
    private var runTask: Task<Void, Never>?
    private var pendingFetches: [Task<Data, Error>] = []

    init(client: NaturalVoiceClient = .live, player: NaturalVoiceAudioPlaying? = nil) {
        self.client = client
        self.player = player ?? NaturalVoiceAudioPlayer()
    }

    /// The server picks the voice for the article's language; the picker lists device voices.
    var availableVoices: [ReadAloudVoiceOption] { [] }

    func speak(
        _ chunks: [String],
        from startIndex: Int,
        voiceIdentifier: String?,
        rate: Double,
        generation: Int,
        onEvent: @escaping @MainActor (Int, SpeechEngineEvent) -> Void
    ) {
        stop()
        NaturalVoiceDiagnostics.lastFailure = nil
        let sentences = ReadAloudSentences.sentences(of: chunks, from: startIndex)
        let languageCode = NaturalVoiceLanguage.code(for: ReadAloudText.dominantLanguage(of: chunks) ?? "en")
        let requests = sentences.map {
            NaturalVoiceRequest(text: $0.text, languageCode: languageCode, voice: nil, speakingRate: rate)
        }
        readAloudLog.debug("natural voice queued \(sentences.count) sentences gen \(generation)")
        runTask = Task { [weak self] in
            await self?.run(sentences, requests: requests, generation: generation, onEvent: onEvent)
        }
    }

    func pause() { player.pause() }
    func resume() { player.resume() }

    func stop() {
        runTask?.cancel()
        runTask = nil
        pendingFetches.forEach { $0.cancel() }
        pendingFetches = []
        player.stop()
    }

    private func run(
        _ sentences: [ReadAloudSentence],
        requests: [NaturalVoiceRequest],
        generation: Int,
        onEvent: @escaping @MainActor (Int, SpeechEngineEvent) -> Void
    ) async {
        var nextFetch: Task<Data, Error>? = sentences.isEmpty ? nil : fetch(requests[0])
        for (index, sentence) in sentences.enumerated() {
            guard let currentFetch = nextFetch else { return }
            let isFirstOfChunk = index == 0 || sentences[index - 1].chunk != sentence.chunk
            let isLastOfChunk = index == sentences.count - 1 || sentences[index + 1].chunk != sentence.chunk
            let audio: Data?
            do {
                audio = try await currentFetch.value
            } catch NaturalVoiceError.sentenceRejected {
                audio = nil
            } catch let error as NaturalVoiceError {
                guard !Task.isCancelled else { return }
                onFailure?(error, sentence, generation)
                return
            } catch {
                return // cancelled
            }
            guard !Task.isCancelled else { return }
            nextFetch = requests.indices.contains(index + 1) ? fetch(requests[index + 1]) : nil
            if isFirstOfChunk { onEvent(generation, .chunkStarted(sentence.chunk)) }
            if let audio {
                onEvent(generation, .sentence(chunk: sentence.chunk, range: sentence.range))
                do { try await player.play(audio) } catch { return } // stopped
            } else {
                await speakRejectedSentence?(sentence, generation)
            }
            guard !Task.isCancelled else { return }
            if isLastOfChunk { onEvent(generation, .chunkFinished(sentence.chunk)) }
        }
    }

    private func fetch(_ request: NaturalVoiceRequest) -> Task<Data, Error> {
        let client = client
        let task = Task { try await client.audio(for: request) }
        pendingFetches = pendingFetches.suffix(1) + [task] // only the current + prefetched matter
        return task
    }
}
