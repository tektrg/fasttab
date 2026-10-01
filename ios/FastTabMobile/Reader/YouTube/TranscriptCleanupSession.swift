import Foundation
import IndieTextCleanup
import UIKit

/// On-device clean-up of the open transcript (engine: IndieTextCleanup). Runs while the reader is
/// open and the app is in front: the page shows the original at once, and each paragraph swaps to
/// its clean text as it lands, on-screen ones first. Progress is saved per video, so a later open
/// shows the clean version at once and only finishes what is missing. Devices without Apple
/// Intelligence get no clean-up and no toggle.
@MainActor
final class TranscriptCleanupSession: ObservableObject {
    /// One paragraph as the page shows it: `v` is "clean" or "original" (reader_template.html).
    struct ParagraphText: Encodable, Equatable {
        let i: Int
        let text: String
        let v: String
    }

    @Published private(set) var isCleaning = false
    @Published private(set) var showsClean: Bool

    let videoID: String
    let originals: [String]
    private var cleaned: [String?]
    private let cleaner: any TextCleaning
    private let canClean: Bool
    private let store: TranscriptCleanupStore
    private let defaults: UserDefaults
    private let isAppActive: @MainActor () -> Bool
    private var runTask: Task<Void, Never>?
    private var run: ChunkedTextCleanup?
    /// Paragraph index for each item of the current run.
    private var runIndices: [Int] = []
    private var visibleParagraphs: ClosedRange<Int>?
    private var isOpen = false
    private var activeObserver: NSObjectProtocol?

    static let showsCleanKey = "reader.transcriptShowsClean"

    init(videoID: String, originals: [String],
         cleaner: any TextCleaning = FoundationModelTextCleaner(),
         canClean: Bool = FoundationModelTextCleaner.isAvailable,
         store: TranscriptCleanupStore = .shared,
         defaults: UserDefaults = .standard,
         isAppActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.isAppActive = isAppActive
        self.videoID = videoID
        self.originals = originals
        self.cleaner = cleaner
        self.canClean = canClean
        self.store = store
        self.defaults = defaults
        self.showsClean = defaults.object(forKey: Self.showsCleanKey) as? Bool ?? true
        self.cleaned = store.record(videoID: videoID, originals: originals)?.texts
            ?? Array(repeating: nil, count: originals.count)
    }

    /// Whether to offer the Clean / Original toggle: the model is here, or a saved clean-up is.
    var isOffered: Bool { canClean || cleaned.contains { $0 != nil } }

    var isComplete: Bool { !cleaned.contains(nil) }

    /// Every paragraph as it should be shown now.
    var shownTexts: [ParagraphText] {
        originals.indices.map { index in
            if showsClean, let clean = cleaned[index] { return ParagraphText(i: index, text: clean, v: "clean") }
            return ParagraphText(i: index, text: originals[index], v: "original")
        }
    }

    /// The reader opened (or came back): start or resume cleaning what is missing.
    func open() {
        isOpen = true
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeIfNeeded() }
            }
        }
        resumeIfNeeded()
    }

    /// The reader closed: stop asking the model. Saved progress stays.
    func close() {
        isOpen = false
        runTask?.cancel()
        runTask = nil
        run = nil
        isCleaning = false
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    func setShowsClean(_ on: Bool) {
        showsClean = on
        defaults.set(on, forKey: Self.showsCleanKey)
    }

    /// The page reports which paragraphs are on screen; those are cleaned next.
    func paragraphsVisible(_ range: ClosedRange<Int>) {
        visibleParagraphs = range
        prioritizeVisible()
    }

    private func resumeIfNeeded() {
        guard isOpen, canClean, runTask == nil, !isComplete,
              isAppActive() else { return }
        let pending = cleaned.indices.filter { cleaned[$0] == nil }
        let run = ChunkedTextCleanup(items: pending.map { originals[$0] },
                                     instruction: TranscriptCleanup.instruction,
                                     cleaner: cleaner,
                                     maxConcurrentChunks: TranscriptCleanup.maxConcurrentChunks)
        self.run = run
        runIndices = pending
        isCleaning = true
        prioritizeVisible()
        runTask = Task { [weak self] in
            _ = try? await run.run { [weak self] items in await self?.settle(items, from: run) }
            self?.runFinished(run)
        }
    }

    private func prioritizeVisible() {
        guard let run, let visibleParagraphs else { return }
        let positions = runIndices.indices.filter { visibleParagraphs.contains(runIndices[$0]) }
        Task { await run.prioritize(positions) }
    }

    private func settle(_ items: [CleanedItem], from finishedRun: ChunkedTextCleanup) {
        guard finishedRun === run else { return }
        var changed = false
        for item in items where item.isSettled && item.index < runIndices.count {
            cleaned[runIndices[item.index]] = item.text
            changed = true
        }
        guard changed else { return }
        store.save(TranscriptCleanupRecord(sourceDigest: TranscriptCleanupStore.digest(originals), texts: cleaned),
                   videoID: videoID)
        objectWillChange.send()
    }

    /// Done, or stopped because the model became unavailable (the app left the front, rate
    /// limit): the rest resumes on the next foreground or open.
    private func runFinished(_ finishedRun: ChunkedTextCleanup) {
        guard finishedRun === run else { return }
        run = nil
        runTask = nil
        isCleaning = false
    }
}
