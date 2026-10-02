import AVFoundation
import MediaPlayer

/// Plays one article aloud, paragraph by paragraph, through a `SpeechEngine`.
/// Owns the audio session (background playback) and the lock-screen Now Playing
/// entry + play/pause remote commands. One instance per open reader.
@MainActor
final class ReadAloudController: ObservableObject {
    enum PlaybackState: Equatable { case idle, playing, paused }

    @Published private(set) var state: PlaybackState = .idle

    private let engine: SpeechEngine
    private let settingsStore: ReaderReadingSettingsStore
    private var chunks: [String] = []
    private var chunkIndex = 0
    private var articleTitle = ""
    private var siteName = ""
    private var voiceIdentifier: String?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []

    init(engine: SpeechEngine? = nil, settingsStore: ReaderReadingSettingsStore = .shared) {
        self.engine = engine ?? AppleSpeechEngine()
        self.settingsStore = settingsStore
    }

    var availableVoices: [ReadAloudVoiceOption] { engine.availableVoices }

    /// Play/Pause button: starts the article, pauses, or resumes.
    func togglePlayback(article: ReaderArticle) {
        switch state {
        case .idle: start(article: article)
        case .playing: pause()
        case .paused: resume()
        }
    }

    func start(article: ReaderArticle) {
        stop()
        chunks = ReadAloudText.chunks(for: article)
        guard !chunks.isEmpty else { return }
        articleTitle = article.title
        siteName = article.siteName.isEmpty ? (article.url.host ?? "") : article.siteName
        voiceIdentifier = ReadAloudVoiceSelector.select(
            preferredIdentifier: settingsStore.settings.speechVoiceIdentifier,
            languageCode: ReadAloudText.dominantLanguage(of: chunks),
            among: engine.availableVoices
        )?.id
        chunkIndex = 0
        activateAudioSession()
        registerRemoteCommands()
        state = .playing
        speakCurrentChunk()
    }

    func pause() {
        guard state == .playing else { return }
        engine.pause()
        state = .paused
        updateNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        activateAudioSession()
        engine.resume()
        state = .playing
        updateNowPlaying()
    }

    /// Ends playback and clears the lock-screen entry (also used when leaving the article).
    func stop() {
        guard state != .idle else { return }
        engine.stop()
        state = .idle
        chunks = []
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Chunk loop

    private func speakCurrentChunk() {
        guard chunkIndex < chunks.count else { stop(); return }
        updateNowPlaying()
        // Rate is re-read per chunk so a speed change applies from the next paragraph.
        engine.speak(
            chunks[chunkIndex],
            voiceIdentifier: voiceIdentifier,
            rate: settingsStore.settings.effectiveSpeechRate
        ) { [weak self] in
            guard let self, self.state != .idle else { return }
            self.chunkIndex += 1
            self.speakCurrentChunk()
        }
    }

    // MARK: - System integration

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: articleTitle,
            MPMediaItemPropertyArtist: siteName,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
    }

    private func registerRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (ReadAloudController) -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                MainActor.assumeIsolated { action(self) }
                return .success
            }
            remoteCommandTargets.append((command, target))
        }
        add(center.playCommand) { $0.resume() }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.state == .playing ? $0.pause() : $0.resume() }
    }

    private func unregisterRemoteCommands() {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        remoteCommandTargets = []
    }
}
