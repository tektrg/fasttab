import AVFoundation
import Combine
import MediaPlayer

/// Plays one article aloud through a `SpeechEngine`. Owns the audio session
/// (background playback, interruptions) and the lock-screen Now Playing entry +
/// play/pause remote commands. One instance per open reader.
///
/// Single source of truth: `generation` identifies the current engine run and
/// `currentChunk` the paragraph being spoken. Engine events from any other
/// generation, or for a chunk other than the current one, are dropped. Every state
/// transition goes through `transition(to:)`, which also clears the highlight.
@MainActor
final class ReadAloudController: ObservableObject {
    enum PlaybackState: Equatable { case idle, playing, paused }

    @Published private(set) var state: PlaybackState = .idle
    /// Word being spoken; nil whenever not actively speaking (the page clears its highlight).
    @Published private(set) var spokenPosition: ReadAloudSpokenPosition?
    /// Set when the user scrolls by hand during playback; "Back to reading" clears it.
    @Published var isAutoScrollPaused = false
    /// The chunks of the current session, for mapping `spokenPosition` onto the page.
    private(set) var chunks: [String] = []
    /// Paragraph being spoken (or about to resume).
    private(set) var currentChunk = 0

    private let engine: SpeechEngine
    private let settingsStore: ReaderReadingSettingsStore
    private let integratesWithSystem: Bool
    /// Bumped on every engine (re)start; also the page's session id for its text map.
    private var generation = 0
    private var articleTitle = ""
    private var siteName = ""
    private var voiceIdentifier: String?
    private var languageCode: String?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var settingsSubscription: AnyCancellable?

    /// `integratesWithSystem: false` keeps tests away from the audio session and lock screen.
    init(
        engine: SpeechEngine? = nil,
        settingsStore: ReaderReadingSettingsStore = .shared,
        integratesWithSystem: Bool = true
    ) {
        self.engine = engine ?? AppleSpeechEngine()
        self.settingsStore = settingsStore
        self.integratesWithSystem = integratesWithSystem
        // Speed / voice changes restart the current paragraph with the new settings.
        // `$settings` fires before the store's value changes, so the new value is passed on.
        settingsSubscription = settingsStore.$settings
            .removeDuplicates { $0.speechRate == $1.speechRate && $0.speechVoiceIdentifier == $1.speechVoiceIdentifier }
            .dropFirst()
            .sink { [weak self] settings in self?.settingsDidChange(settings) }
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
        languageCode = ReadAloudText.dominantLanguage(of: chunks)
        isAutoScrollPaused = false
        if integratesWithSystem {
            activateAudioSession()
            registerRemoteCommands()
            observeAudioSession()
        }
        runEngine(from: 0, settings: settingsStore.settings)
    }

    func pause() {
        guard state == .playing else { return }
        engine.pause()
        transition(to: .paused)
    }

    func resume() {
        guard state == .paused else { return }
        if integratesWithSystem { activateAudioSession() }
        engine.resume()
        transition(to: .playing)
    }

    /// Ends playback and clears the lock-screen entry (also used when leaving the article).
    func stop() {
        guard state != .idle else { return }
        engine.stop()
        generation += 1 // anything the old run still delivers is now stale
        transition(to: .idle)
        isAutoScrollPaused = false
        chunks = []
        currentChunk = 0
        guard integratesWithSystem else { return }
        unregisterRemoteCommands()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - State machine

    private func transition(to newState: PlaybackState) {
        readAloudLog.info("state \(String(describing: self.state)) -> \(String(describing: newState)) chunk \(self.currentChunk) gen \(self.generation)")
        spokenPosition = nil
        state = newState
        if integratesWithSystem, newState != .idle { updateNowPlaying() }
    }

    /// (Re)starts the engine at `chunk` under a fresh generation.
    private func runEngine(from chunk: Int, settings: ReaderReadingSettings) {
        engine.stop()
        generation += 1
        currentChunk = chunk
        voiceIdentifier = ReadAloudVoiceSelector.select(
            preferredIdentifier: settings.speechVoiceIdentifier,
            languageCode: languageCode,
            among: engine.availableVoices
        )?.id
        transition(to: .playing)
        engine.speak(
            chunks,
            from: chunk,
            voiceIdentifier: voiceIdentifier,
            rate: settings.effectiveSpeechRate,
            generation: generation
        ) { [weak self] generation, event in
            self?.handle(event, generation: generation)
        }
    }

    func handle(_ event: SpeechEngineEvent, generation eventGeneration: Int) {
        guard eventGeneration == generation, state != .idle else {
            readAloudLog.debug("dropped stale \(String(describing: event)) gen \(eventGeneration) (current \(self.generation))")
            return
        }
        switch event {
        case .chunkStarted(let chunk):
            readAloudLog.debug("utterance start chunk \(chunk) gen \(eventGeneration)")
            currentChunk = chunk
        case .word(let chunk, let range):
            guard chunk == currentChunk, state == .playing else { return }
            spokenPosition = ReadAloudSpokenPosition(sessionID: generation, chunkIndex: chunk, wordRange: range)
        case .chunkFinished(let chunk):
            readAloudLog.debug("utterance finish chunk \(chunk) gen \(eventGeneration)")
            guard chunk == chunks.count - 1 else { return }
            readAloudLog.info("article finished")
            stop()
        }
    }

    private func settingsDidChange(_ settings: ReaderReadingSettings) {
        switch state {
        case .playing: runEngine(from: currentChunk, settings: settings)
        case .paused:
            // Restart paused at the same paragraph so resume uses the new settings.
            runEngine(from: currentChunk, settings: settings)
            pause()
        case .idle: break
        }
    }

    // MARK: - System integration

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
            try session.setActive(true)
        } catch {
            readAloudLog.error("audio session activation failed: \(error.localizedDescription)")
        }
    }

    /// Calls, Siri, alarms pause speech; without this the UI stayed "playing" in silence.
    private func observeAudioSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            MainActor.assumeIsolated { self?.audioSessionInterrupted(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard reasonRaw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated {
                readAloudLog.info("headphones removed: pausing")
                self?.pause()
            }
        })
    }

    private func audioSessionInterrupted(typeRaw: UInt?, optionsRaw: UInt) {
        switch typeRaw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) {
        case .began:
            readAloudLog.info("audio interruption began")
            pause()
        case .ended where AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume):
            readAloudLog.info("audio interruption ended: resuming")
            resume()
        default:
            break
        }
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
