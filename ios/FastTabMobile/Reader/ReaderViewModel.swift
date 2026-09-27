import SwiftUI
import Combine

/// State & business logic for a single reader session.
/// Drives `ReaderView` via `@StateObject`.
@MainActor
public final class ReaderViewModel: ObservableObject {

    // MARK: - Published State

    public enum LoadState: Equatable {
        case idle
        case extracting
        case loaded(ReaderArticle)
        case failed(Error)

        public static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case (.extracting, .extracting):
                return true
            case (.loaded(let a), .loaded(let b)):
                return a == b
            case (.failed(let e1), .failed(let e2)):
                return e1.localizedDescription == e2.localizedDescription
            default:
                return false
            }
        }
    }

    public var isFailed: Bool {
        if case .failed = loadState { return true }
        return false
    }

    /// True when extraction failed on an X Article; the view shows Safari Reader instead.
    public var needsSafariReader: Bool {
        guard case .failed(let error) = loadState,
              let extraction = error as? ReaderExtractor.ExtractionError,
              case .xArticleUnavailable = extraction else { return false }
        return true
    }

    @Published public var loadState: LoadState = .idle
    /// Current reading scroll progress [0.0 – 1.0]. Not @Published to prevent redundant
    /// SwiftUI view-graph invalidations and main-thread re-renders during active scrolling.
    public var scrollProgress: Double = 0.0
    @Published public var highlights: [ReaderHighlight] = []
    /// Live mirror of `ReaderReadingSettingsStore.shared.settings`. Mutate through
    /// `readingSettings` (the store) so changes persist + sync via iCloud KVS.
    @Published public var readerSettings: ReaderReadingSettings = ReaderReadingSettingsStore.shared.settings
    /// Backwards-compatible accessor for the article font size in pts (CSS variable).
    public var fontSize: Int { readerSettings.fontSize }
    @Published public var pendingHighlightToApply: ReaderHighlight? = nil
    @Published public var highlightToRemoveID: String? = nil
    @Published public var pendingClearAllHighlights: Bool = false

    // MARK: - Inputs

    public let url: URL
    public let title: String
    /// Highlight to scroll to and flash on load, set when opened from `HighlightsListView`
    /// or the Read tab's Recent Highlights carousel. `nil` restores the last scroll position instead.
    public let focusHighlightID: String?

    // MARK: - Dependencies (lazy so init is nonisolated-safe)

    private var progressStore: ReaderReadingProgress { .shared }
    private var highlightStore: ReaderHighlightStore { .shared }
    private var articleCache: ReaderArticleCache { .shared }
    private var settingsStore: ReaderReadingSettingsStore { .shared }
    private var statsRecorder: ReadingStatsRecorder { .shared }
    /// Words in the loaded article, counted once per extraction (off the main thread) for stats.
    private var articleWordCount: Int?
    private var wordCountTask: Task<Void, Never>?
    private var settingsCancellable: AnyCancellable?

    // MARK: - Init

    public init(url: URL, title: String, focusHighlightID: String? = nil) {
        self.url = url
        self.title = title
        self.focusHighlightID = focusHighlightID
        self.readerSettings = settingsStore.settings
        settingsCancellable = settingsStore.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.readerSettings = $0 }
    }

    /// Called from `ReaderView.onAppear` — safe to record history side-effects here.
    public func loadInitialState() {
        LastOpenedStore.shared.recordOpened(url: url, title: title)
        scrollProgress = progressStore.progress(for: url)
        statsRecorder.beginReading(url: url, savedProgress: scrollProgress)
        highlights = highlightStore.highlights(for: url)

        // Instant load from cache if previously processed
        if case .idle = loadState, let cached = articleCache.article(for: url) {
            loadState = .loaded(cached)
        }
    }

    // MARK: - Extraction

    public func extractIfNeeded(force: Bool = false) async {
        if !force {
            if case .loaded = loadState { return }
            if let cached = articleCache.article(for: url) {
                loadState = .loaded(cached)
                return
            }
            guard case .idle = loadState else { return }
        }

        loadState = .extracting
        do {
            let article = try await ReaderExtractor.shared.extract(url: url)
            articleCache.save(article)
            articleWordCount = nil
            wordCountTask?.cancel()
            wordCountTask = nil
            loadState = .loaded(article)
        } catch {
            loadState = .failed(error)
        }
    }

    /// Forces re-extraction of the article from the web, updating the cache.
    public func reloadArticle() async {
        await extractIfNeeded(force: true)
    }

    // MARK: - Scroll Progress

    private var pendingPersistTask: Task<Void, Never>?

    public func updateScrollProgress(_ progress: Double, immediate: Bool = false) {
        scrollProgress = progress
        if immediate {
            // `immediate` is a finished scroll gesture, not the reader closing: stats still
            // batch small gains until a real flush.
            persistProgressNow(statsFlush: false)
        } else {
            schedulePersist(progress: progress)
        }
    }

    private func schedulePersist(progress: Double) {
        pendingPersistTask?.cancel()
        pendingPersistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            progressStore.set(progress: progress, for: url)
            LastOpenedStore.shared.updateProgress(url: url, progress: progress)
            recordReadingStats(progress: progress, isFlush: false)
        }
    }

    /// Flushes any pending progress persistence immediately (e.g. on view dismiss/disappear)
    public func flushPendingProgress() {
        persistProgressNow(statsFlush: true)
    }

    private func persistProgressNow(statsFlush: Bool) {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        progressStore.set(progress: scrollProgress, for: url)
        LastOpenedStore.shared.updateProgress(url: url, progress: scrollProgress)
        recordReadingStats(progress: scrollProgress, isFlush: statsFlush)
    }

    /// Stats only count once the article is on screen: before that, progress is a restored
    /// position, not reading. Until the word count lands nothing is recorded, and the ledger
    /// keeps the unrecorded ground for the next update.
    private func recordReadingStats(progress: Double, isFlush: Bool) {
        guard case .loaded(let article) = loadState, statsRecorder.isTracked(url) else { return }
        guard let wordCount = articleWordCount else {
            startWordCountIfNeeded(article)
            return
        }
        statsRecorder.recordProgress(url: url, title: title, progress: progress, wordCount: wordCount, isFlush: isFlush)
    }

    private func startWordCountIfNeeded(_ article: ReaderArticle) {
        guard wordCountTask == nil else { return }
        wordCountTask = Task { [weak self] in
            let wordCount = await Task.detached(priority: .utility) { article.readingWordCount }.value
            guard !Task.isCancelled, let self else { return }
            self.articleWordCount = wordCount
            self.recordReadingStats(progress: self.scrollProgress, isFlush: false)
        }
    }

    // MARK: - Highlights

    public func commitHighlight(selectedText: String, serializedRange: String, color: HighlightColor) {
        let h = ReaderHighlight(
            urlKey: url.readerCanonicalKey,
            selectedText: selectedText,
            color: color,
            serializedRange: serializedRange,
            title: title,
            urlString: url.absoluteString
        )
        highlightStore.add(h)
        statsRecorder.recordHighlight(url: url, title: title)
        highlights = highlightStore.highlights(for: url)
        pendingHighlightToApply = h
    }

    public func removeHighlight(id: String) {
        highlightStore.remove(id: id, url: url)
        highlights = highlightStore.highlights(for: url)
        highlightToRemoveID = id
    }

    public func clearAllHighlights() {
        highlightStore.removeAll(for: url)
        highlights = []
        pendingClearAllHighlights = true
    }

    // MARK: - Reading Settings (persisted + iCloud-synced via the store)

    public func increaseFontSize() { settingsStore.setFontSize(fontSize + 2) }
    public func decreaseFontSize() { settingsStore.setFontSize(fontSize - 2) }
}

