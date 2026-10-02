import AVFoundation

/// Plays one sentence of audio at a time. A protocol so engine tests run without audio.
@MainActor
protocol NaturalVoiceAudioPlaying: AnyObject {
    /// Returns when the audio finished; throws `CancellationError` when `stop` cut it off.
    /// A `pause()` issued before `play` keeps the new sentence paused until `resume()`.
    func play(_ audio: Data) async throws
    func pause()
    func resume()
    /// Ends the current sentence and clears the paused flag.
    func stop()
}

@MainActor
final class NaturalVoiceAudioPlayer: NSObject, NaturalVoiceAudioPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Error>?
    private var isPaused = false

    func play(_ audio: Data) async throws {
        finish(throwing: CancellationError()) // never two sentences at once
        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            if !isPaused { player.play() }
        }
    }

    func pause() {
        isPaused = true
        player?.pause()
    }

    func resume() {
        isPaused = false
        player?.play()
    }

    func stop() {
        isPaused = false
        player?.stop()
        player = nil
        finish(throwing: CancellationError())
    }

    private func finish(throwing error: Error?) {
        guard let continuation = finished else { return }
        finished = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finishedPlayer = ObjectIdentifier(player)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let current = self.player, ObjectIdentifier(current) == finishedPlayer else { return }
                self.player = nil
                self.finish(throwing: nil)
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false) // skip the bad sentence
    }
}
