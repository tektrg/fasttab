import FastTabSync
import Foundation

/// The Mac reader's `ReadSession`: starts when the page loads with its saved position;
/// progress committed before that never counts.
@MainActor
final class MacReadSessionTracker {
    private var session: ReadSession?

    func begin(startProgress: Double) {
        session = ReadSession(startProgress: startProgress)
    }

    /// True once per session, on the commit that finishes a reread.
    func record(progress: Double) -> Bool {
        session?.record(progress: progress) ?? false
    }
}

/// Collects the reader's scroll position and writes it to the FastTab List at most once per
/// `delay` (each write is a sync send), right away when the page asks (scroll end, close), and
/// on `flush()`. `FastTabListLibrary.recordProgress` turns ≥ 90 % into "read" (readAt).
@MainActor
final class MacReaderProgressSink {
    static let defaultDelay: Duration = .seconds(2)
    /// A page shorter than the window is read once it has been open this long.
    static let shortArticleDwell: Duration = .seconds(4)

    private let delay: Duration
    private let commit: (Double) -> Void
    private var pending: Double?
    private var pendingTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?

    init(delay: Duration = MacReaderProgressSink.defaultDelay, commit: @escaping (Double) -> Void) {
        self.delay = delay
        self.commit = commit
    }

    func receive(progress: Double, immediate: Bool) {
        pending = progress
        if immediate { flush(); return }
        guard pendingTask == nil else { return }
        pendingTask = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// The page fits the window, so there is nothing to scroll: count it read after a dwell.
    func contentFitsViewport(_ fits: Bool) {
        dwellTask?.cancel()
        dwellTask = nil
        guard fits else { return }
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.shortArticleDwell)
            guard !Task.isCancelled else { return }
            self?.receive(progress: 1, immediate: true)
        }
    }

    func flush() {
        pendingTask?.cancel()
        pendingTask = nil
        guard let progress = pending else { return }
        pending = nil
        commit(progress)
    }

    func stop() {
        dwellTask?.cancel()
        flush()
    }
}
