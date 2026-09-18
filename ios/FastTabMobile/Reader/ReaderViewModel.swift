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

    @Published public var loadState: LoadState = .idle
    /// Current reading scroll progress [0.0 – 1.0]. Not @Published to prevent redundant
    /// SwiftUI view-graph invalidations and main-thread re-renders during active scrolling.
    public var scrollProgress: Double = 0.0
    @Published public var highlights: [ReaderHighlight] = []
    @Published public var fontSize: Int = 18              // pts, CSS variable
    @Published public var pendingHighlightToApply: ReaderHighlight? = nil
    @Published public var highlightToRemoveID: String? = nil
    @Published public var pendingClearAllHighlights: Bool = false

    // MARK: - Inputs

    public let url: URL
    public let title: String

    // MARK: - Dependencies (lazy so init is nonisolated-safe)

    private var progressStore: ReaderReadingProgress { .shared }
    private var highlightStore: ReaderHighlightStore { .shared }
    private var articleCache: ReaderArticleCache { .shared }

    // MARK: - Init

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    /// Called from `ReaderView.onAppear` — safe to record history side-effects here.
    public func loadInitialState() {
        LastOpenedStore.shared.recordOpened(url: url, title: title)
        scrollProgress = progressStore.progress(for: url)
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
            flushPendingProgress()
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
        }
    }

    /// Flushes any pending progress persistence immediately (e.g. on view dismiss/disappear)
    public func flushPendingProgress() {
        pendingPersistTask?.cancel()
        pendingPersistTask = nil
        progressStore.set(progress: scrollProgress, for: url)
        LastOpenedStore.shared.updateProgress(url: url, progress: scrollProgress)
    }

    // MARK: - Highlights

    public func commitHighlight(selectedText: String, serializedRange: String, color: HighlightColor) {
        let h = ReaderHighlight(
            urlKey: url.readerCanonicalKey,
            selectedText: selectedText,
            color: color,
            serializedRange: serializedRange
        )
        highlightStore.add(h)
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

    // MARK: - Font Size

    public func increaseFontSize() { fontSize = min(fontSize + 2, 28) }
    public func decreaseFontSize() { fontSize = max(fontSize - 2, 14) }
}

