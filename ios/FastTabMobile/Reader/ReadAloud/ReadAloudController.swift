import AVFoundation
import Combine
import MediaPlayer

/// Plays one article aloud through a `SpeechEngine`. Owns the audio session
/// (background playback, interruptions) and the lock-screen Now Playing entry +
/// remote commands (play/pause, ±15 s skips from the lock screen, headphones and car).
/// One instance per open reader.
///
/// Single source of truth: `generation` identifies the current engine run and
/// `currentChunk` the paragraph being spoken. Engine events from any other
/// generation, or for a chunk other than the current one, are dropped. Every state
/// transition goes through `transition(to:)`, which also clears the highlight.
@MainActor
final class ReadAloudController: ObservableObject {
    enum PlaybackState: Equatable { case idle, playing, paused }

    @Published private(set) var state: PlaybackState = .idle
    /// Word / sentence being spoken; nil whenever not actively speaking (the page clears its
    /// highlight), except paused right after a skip: then the target sentence (`parkPaused`).
    @Published private(set) var spokenPosition: ReadAloudSpokenPosition?
    /// Set when the user scrolls by hand during playback; "Back to reading" clears it.
    @Published var isAutoScrollPaused = false
    /// The chunks of the current session, for mapping `spokenPosition` onto the page.
    private(set) var chunks: [String] = []
    /// Paragraph being spoken (or about to resume).
    private(set) var currentChunk = 0
    /// UTF-16 offset in `currentChunk` of the last word/sentence spoken (where a ±15 s skip
    /// measures from); the run's start offset until the engine reports one.
    private(set) var currentOffset = 0
    /// Where the current engine run began (mid-chunk after a skip).
    private var runStart = ReadAloudPosition(chunk: 0, offset: 0)
    /// Set by a skip while paused: the run is parked at this sentence start. The page shows that
    /// sentence, and Play / resume continue from it whatever is on screen. Cleared by any state
    /// change (resume, a new run, stop).
    private var pausedSkipTarget: ReadAloudPosition?
    var currentPosition: ReadAloudPosition { ReadAloudPosition(chunk: currentChunk, offset: currentOffset) }
    /// True once Read Aloud was started in this reader; only then does tapping a
    /// paragraph start/jump playback (no surprise speech on an ordinary tap).
    @Published private(set) var hasBeenUsed = false
    /// The last run read through to the end: the next Play starts from the title.
    private(set) var finishedArticle = false
    /// The open page, asked what is on screen when Play is pressed (set by the reader).
    weak var page: ReadAloudPageSync?

    /// Free device voice; also the natural voice's fallback.
    private let deviceEngine: SpeechEngine
    private let makeNaturalEngine: (SpeechEngine) -> SpeechEngine
    private lazy var naturalEngine: SpeechEngine = makeNaturalEngine(deviceEngine)
    /// English voice (beta, on-device Paradee); falls back to the device voice itself.
    private let makeParadeeEngine: (SpeechEngine) -> SpeechEngine
    private lazy var paradeeEngine: SpeechEngine = makeParadeeEngine(deviceEngine)
    /// The build offers the English voice switch (tests pass a constant).
    private let isParadeeOffered: @MainActor () -> Bool
    /// The engine of the current run (picked from settings on every (re)start).
    private var engine: SpeechEngine
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
    /// The Natural Voice subscription (tests pass a constant).
    private let isNaturalVoiceEntitled: @MainActor () -> Bool

    /// `integratesWithSystem: false` keeps tests away from the audio session and lock screen.
    init(
        engine: SpeechEngine? = nil,
        naturalEngine makeNaturalEngine: ((_ deviceEngine: SpeechEngine) -> SpeechEngine)? = nil,
        paradeeEngine makeParadeeEngine: ((_ deviceEngine: SpeechEngine) -> SpeechEngine)? = nil,
        settingsStore: ReaderReadingSettingsStore = .shared,
        integratesWithSystem: Bool = true,
        isNaturalVoiceEntitled: @escaping @MainActor () -> Bool = { NaturalVoiceAccess.shared.isEntitled },
        isParadeeOffered: @escaping @MainActor () -> Bool = { ParadeeGate.isOfferedInThisBuild }
    ) {
        self.isNaturalVoiceEntitled = isNaturalVoiceEntitled
        self.isParadeeOffered = isParadeeOffered
        self.makeParadeeEngine = makeParadeeEngine ?? { device in
            ParadeeSpeechEngine(device: device, preferredDeviceVoice: { settingsStore.settings.speechVoiceIdentifier })
        }
        let deviceEngine = engine ?? AppleSpeechEngine()
        self.deviceEngine = deviceEngine
        self.engine = deviceEngine
        self.makeNaturalEngine = makeNaturalEngine ?? { device in
            NaturalVoiceSpeechEngine(natural: GoogleSpeechEngine(), device: device)
        }
        self.settingsStore = settingsStore
        self.integratesWithSystem = integratesWithSystem
        // Speed / voice / natural-voice changes restart the current paragraph with the new settings.
        // `$settings` fires before the store's value changes, so the new value is passed on.
        settingsSubscription = settingsStore.$settings
            .removeDuplicates {
                $0.speechRate == $1.speechRate && $0.speechVoiceIdentifier == $1.speechVoiceIdentifier
                    && $0.naturalVoiceEnabled == $1.naturalVoiceEnabled
                    && $0.paradeeVoiceEnabled == $1.paradeeVoiceEnabled && $0.paradeeVoiceID == $1.paradeeVoiceID
            }
            .dropFirst()
            .sink { [weak self] settings in self?.settingsDidChange(settings) }
    }

    var availableVoices: [ReadAloudVoiceOption] { deviceEngine.availableVoices }

    /// Latest engine notice (e.g. natural voice fell back); the view shows it briefly.
    struct EngineNotice: Equatable {
        let message: String
        let id: Int
    }
    @Published private(set) var engineNotice: EngineNotice?

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
            pausedAtSkipTarget: pausedSkipTarget != nil,
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
        let parked = pausedSkipTarget
        if integratesWithSystem { activateAudioSession() }
        engine.resume()
        transition(to: .playing)
        // Keep the skip target lit until the run reports its own progress (sentence voices
        // already sent their first sentence while paused, and those events were dropped).
        if let parked { spokenPosition = highlight(at: parked) }
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
        currentOffset = 0
        guard integratesWithSystem else { return }
        unregisterRemoteCommands()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Skip ±15 s

    /// Back / forward ~15 s of speech (`ReadAloudSkip`): restarts the engine at the start of
    /// the nearest sentence, so the page highlight and auto-scroll follow. Paused stays paused
    /// at the new place, with that sentence highlighted (`parkPaused`); forward past the end
    /// stops, like finishing the article.
    func skip(_ direction: ReadAloudSkip.Direction) {
        guard state != .idle, !chunks.isEmpty else { return }
        let wasPaused = state == .paused
        let settings = settingsStore.settings
        let target = ReadAloudSkip.target(chunks: chunks, from: currentPosition,
                                          rate: settings.effectiveSpeechRate, direction: direction)
        readAloudLog.info("skip \(String(describing: direction)) from \(self.currentChunk):\(self.currentOffset) to \(String(describing: target))")
        switch target {
        case .end:
            stop()
            finishedArticle = true
        case .position(let position):
            isAutoScrollPaused = false
            if integratesWithSystem, !wasPaused { activateAudioSession() }
            runEngine(from: position.chunk, offset: position.offset, settings: settings)
            if wasPaused { parkPaused(at: position) }
        }
    }

    /// Pauses the run just started at `position` and shows its sentence on the page (which
    /// scrolls to it, as during playback), so a paused skip is visible and Play keeps it.
    private func parkPaused(at position: ReadAloudPosition) {
        pause()
        pausedSkipTarget = position
        spokenPosition = highlight(at: position)
    }

    /// The sentence containing `position` (the whole rest of the chunk if none), as the page
    /// highlight for the current run.
    private func highlight(at position: ReadAloudPosition) -> ReadAloudSpokenPosition? {
        guard chunks.indices.contains(position.chunk) else { return nil }
        let text = chunks[position.chunk]
        let sentence = ReadAloudSentences.split(text, chunk: position.chunk)
            .first { NSMaxRange($0.range) > position.offset }?.range
        let length = (text as NSString).length
        let offset = min(max(position.offset, 0), length)
        return ReadAloudSpokenPosition(sessionID: generation, chunkIndex: position.chunk,
                                       wordRange: sentence ?? NSRange(location: offset, length: length - offset))
    }

    /// Lock screen, headphone and car buttons. Next/previous track (AirPods double/triple
    /// press, car arrows) skip ±15 s like the lock screen's skip buttons.
    enum RemoteCommand: CaseIterable {
        case play, pause, togglePlayPause, skipBackward, skipForward, previousTrack, nextTrack
    }

    func handleRemoteCommand(_ command: RemoteCommand) {
        readAloudLog.info("remote command \(String(describing: command))")
        switch command {
        case .play: resume()
        case .pause: pause()
        case .togglePlayPause: state == .playing ? pause() : resume()
        case .skipBackward, .previousTrack: skip(.backward)
        case .skipForward, .nextTrack: skip(.forward)
        }
    }

    // MARK: - State machine

    private func transition(to newState: PlaybackState) {
        readAloudLog.info("state \(String(describing: self.state)) -> \(String(describing: newState)) chunk \(self.currentChunk) gen \(self.generation)")
        spokenPosition = nil
        pausedSkipTarget = nil
        state = newState
        if integratesWithSystem, newState != .idle { updateNowPlaying() }
    }

    /// (Re)starts the engine at `offset` (UTF-16) inside `chunk` under a fresh generation.
    /// A mid-chunk start hands the engine that chunk cut short and shifts its ranges back
    /// (`ReadAloudMidChunkStart`), so it works the same for every engine.
    private func runEngine(from chunk: Int, offset: Int = 0, settings: ReaderReadingSettings) {
        engine.stop()
        generation += 1
        currentChunk = chunk
        currentOffset = offset
        runStart = ReadAloudPosition(chunk: chunk, offset: offset)
        if ParadeeGate.routesToParadee(languageCode: languageCode, setting: settings.paradeeVoiceEnabled,
                                       offered: isParadeeOffered()) {
            // English article: the on-device Paradee voice, free (no subscription check).
            engine = paradeeEngine
            voiceIdentifier = ParadeeVoice.resolve(settings.paradeeVoiceID).optionID
        } else {
            let entitled = isNaturalVoiceEntitled()
            engine = NaturalVoiceGate.usesNaturalVoice(toggleOn: settings.wantsNaturalVoice, entitled: entitled) ? naturalEngine : deviceEngine
            voiceIdentifier = ReadAloudVoiceSelector.select(
                preferredIdentifier: settings.speechVoiceIdentifier,
                languageCode: languageCode,
                among: deviceEngine.availableVoices
            )?.id
        }
        transition(to: .playing)
        engine.speak(
            ReadAloudMidChunkStart.cut(chunks, chunk: chunk, offset: offset),
            from: chunk,
            voiceIdentifier: voiceIdentifier,
            rate: settings.effectiveSpeechRate,
            generation: generation
        ) { [weak self] generation, event in
            self?.handle(ReadAloudMidChunkStart.shift(event, inChunk: chunk, by: offset), generation: generation)
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
            currentOffset = chunk == runStart.chunk ? runStart.offset : 0
            if integratesWithSystem, state == .playing { updateNowPlaying() } // re-sync the estimated elapsed time
        case .word(let chunk, let range), .sentence(let chunk, let range):
            guard chunk == currentChunk, state == .playing else { return }
            currentOffset = range.location
            spokenPosition = ReadAloudSpokenPosition(sessionID: generation, chunkIndex: chunk, wordRange: range)
        case .chunkFinished(let chunk):
            readAloudLog.debug("utterance finish chunk \(chunk) gen \(eventGeneration)")
            guard chunk == chunks.count - 1 else { return }
            readAloudLog.info("article finished")
            stop()
            finishedArticle = true
        case .notice(let message):
            readAloudLog.info("engine notice: \(message)")
            engineNotice = EngineNotice(message: message, id: (engineNotice?.id ?? 0) + 1)
        }
    }

    private func settingsDidChange(_ settings: ReaderReadingSettings) {
        switch state {
        case .playing: runEngine(from: currentChunk, settings: settings)
        case .paused:
            // Restart paused at the same paragraph (or the skip target) so resume uses the new settings.
            if let parked = pausedSkipTarget {
                runEngine(from: parked.chunk, offset: parked.offset, settings: settings)
                parkPaused(at: parked)
            } else {
                runEngine(from: currentChunk, settings: settings)
                pause()
            }
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

    /// Elapsed / duration are estimates from text length (`ReadAloudSkip.estimatedTimeline`),
    /// refreshed on every state change, skip and paragraph start; the rate (1 playing, 0
    /// paused) lets iOS run or freeze the clock in between.
    private func updateNowPlaying() {
        let timeline = ReadAloudSkip.estimatedTimeline(chunks: chunks, at: currentPosition,
                                                       rate: settingsStore.settings.effectiveSpeechRate)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: articleTitle,
            MPMediaItemPropertyArtist: siteName,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: timeline.elapsed,
            MPMediaItemPropertyPlaybackDuration: timeline.duration,
        ]
    }

    private func registerRemoteCommands() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ remote: RemoteCommand) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                MainActor.assumeIsolated { self.handleRemoteCommand(remote) }
                return .success
            }
            remoteCommandTargets.append((command, target))
        }
        let interval = [NSNumber(value: ReadAloudSkip.interval)]
        center.skipBackwardCommand.preferredIntervals = interval
        center.skipForwardCommand.preferredIntervals = interval
        add(center.playCommand, .play)
        add(center.pauseCommand, .pause)
        add(center.togglePlayPauseCommand, .togglePlayPause)
        add(center.skipBackwardCommand, .skipBackward)
        add(center.skipForwardCommand, .skipForward)
        add(center.previousTrackCommand, .previousTrack)
        add(center.nextTrackCommand, .nextTrack)
    }

    /// Removes our targets and disables those commands, so the lock screen stops offering them.
    private func unregisterRemoteCommands() {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        remoteCommandTargets = []
    }
}
