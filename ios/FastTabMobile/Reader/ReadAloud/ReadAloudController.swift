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
    /// True once Read Aloud was started in this reader; only then does tapping a
    /// paragraph start/jump playback (no surprise speech on an ordinary tap).
    @Published private(set) var hasBeenUsed = false
    /// The last run read through to the end: the next Play starts from the title.
    private(set) var finishedArticle = false
    /// The open page, asked what is on screen when Play is pressed (set by the reader).
    weak var page: ReadAloudPageSync?

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

    /// Play/Pause button. Play starts where `ReadAloudStartPoint` says (resume, title,
    /// or the paragraph at the top of the screen).
    func togglePlayback(article: ReaderArticle) {
        guard state != .playing else { pause(); return }
        guard let page else { play(article: article, viewport: nil); return }
        page.probeViewport { [weak self] viewport in
            guard let self, self.state != .playing else { return }
            self.play(article: article, viewport: viewport)
        }
    }

    func play(article: ReaderArticle, viewport: ReadAloudViewport?) {
        let isPaused = state == .paused
        let startPoint = ReadAloudStartPoint.decide(
            isPaused: isPaused,
            pausedChunk: currentChunk,
            finishedArticle: finishedArticle,
            chunks: isPaused ? chunks : ReadAloudText.chunks(for: article),
            viewport: viewport
        )
        readAloudLog.info("play: \(String(describing: startPoint))")
        switch startPoint {
        case .resume: resume()
        case .chunk(let chunk): jump(to: chunk, article: article)
        }
    }

    func start(article: ReaderArticle, fromChunk startChunk: Int = 0) {
        stop()
        finishedArticle = false
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
        hasBeenUsed = true
        runEngine(from: min(max(startChunk, 0), chunks.count - 1), settings: settingsStore.settings)
    }

    /// Tap on the article (`offset` in the page's text map, -1 when not on text).
    /// Ignored until Read Aloud was used in this article. Then:
    /// - playing → pause;
    /// - paused → resume, unless a *different* paragraph was tapped: read from there;
    /// - stopped → read from the tapped paragraph (nothing when not on one).
    func handleTap(pageText: String, offset: Int, article: ReaderArticle) {
        guard hasBeenUsed else { return }
        if state == .playing {
            pause()
            showTapFeedback(.paused)
            return
        }
        let targetChunks = state == .idle ? ReadAloudText.chunks(for: article) : chunks
        let tappedChunk = ReadAloudTextLocator(documentText: pageText, chunks: targetChunks)
            .chunkIndex(containing: offset)
        if let tappedChunk, !(state == .paused && tappedChunk == currentChunk) {
            jump(to: tappedChunk, article: article)
        } else if state == .paused {
            resume()
        } else {
            return // stopped, and the tap wasn't on a paragraph
        }
        showTapFeedback(.playing)
    }

    /// Brief centred play/pause glyph so a tap on the page doesn't feel invisible.
    struct TapFeedback: Equatable {
        enum Kind { case playing, paused }
        let kind: Kind
        let id: Int
    }
    @Published private(set) var tapFeedback: TapFeedback?

    private func showTapFeedback(_ kind: TapFeedback.Kind) {
        tapFeedback = TapFeedback(kind: kind, id: (tapFeedback?.id ?? 0) + 1)
    }

    func jump(to chunk: Int, article: ReaderArticle) {
        readAloudLog.info("jump to chunk \(chunk) from \(String(describing: self.state))")
        guard state != .idle, chunks.indices.contains(chunk) else {
            start(article: article, fromChunk: chunk)
            return
        }
        isAutoScrollPaused = false
        if integratesWithSystem { activateAudioSession() }
        runEngine(from: chunk, settings: settingsStore.settings)
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
            finishedArticle = true
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
