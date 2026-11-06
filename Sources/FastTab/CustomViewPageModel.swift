import Foundation
import Combine
import OSLog

/// The AI filter's line on a custom view page (nil = nothing to say).
enum CustomViewSemanticStatus: Equatable {
    /// The view has an AI prompt but Apple Intelligence can't run: the page
    /// shows the structured-filter results (owner decision, no fallback).
    case paused
    /// Checking items; `checked` of `total` have a verdict.
    case sorting(checked: Int, total: Int, isCapped: Bool)
    /// Done, with something worth noting (cap reached and/or items the model
    /// couldn't check). A clean finish clears the status instead.
    case finished(isCapped: Bool, unknown: Int)

    static let pausedMessage = "AI filter paused — requires Apple Intelligence"

    var message: String {
        switch self {
        case .paused:
            return Self.pausedMessage
        case .sorting(let checked, let total, _):
            return "Sorting with Apple Intelligence… \(checked)/\(total)"
        case .finished(let isCapped, let unknown):
            var parts: [String] = []
            if isCapped { parts.append("AI checked the \(CustomViewSemanticFilter.defaultCandidateCap) most recent items") }
            if unknown > 0 { parts.append(unknown == 1 ? "AI couldn't check 1 item" : "AI couldn't check \(unknown) items") }
            return parts.joined(separator: " · ")
        }
    }

    init?(progress: CustomViewSemanticProgress) {
        if progress.becameUnavailable {
            self = .paused
        } else if !progress.isFinished {
            self = .sorting(checked: progress.checked, total: progress.total, isCapped: progress.isCapped)
        } else if progress.isCapped || progress.unknown > 0 {
            self = .finished(isCapped: progress.isCapped, unknown: progress.unknown)
        } else {
            return nil
        }
    }
}

/// What the custom view page currently shows: the active view's matching
/// items, grouped. Owns re-evaluation — on activation, when the view's
/// definition changes, and (debounced) whenever the underlying tab /
/// bookmark / history caches change.
///
/// Pipeline (`refresh`): `CustomViewFilter.evaluate` (off the main thread) →
/// the AI filter when the view has a prompt (`CustomViewSemanticFilter`,
/// progressive: cached matches first, then each finished batch) →
/// `CustomViewGrouping.sections` → publish `snapshot`. A newer refresh
/// supersedes an in-flight one (AI batches already queued are reused).
@MainActor
final class CustomViewPageModel: ObservableObject {
    struct Snapshot: Equatable {
        let viewID: UUID
        let sections: [CustomViewSection]
        /// Index of each section's first row in `items` (keyboard selection
        /// runs over the flat list; headers are decorative).
        let sectionOffsets: [Int]
        /// Rows in display order — the concatenation of `sections`.
        let items: [CustomViewItem]
        /// Bumped on every publish so the UI can react without diffing items.
        let revision: Int
        /// No snapshot with rows was published since the view was activated
        /// (so the UI lands the selection on the first row once rows appear).
        let isInitial: Bool
    }

    static let shared = CustomViewPageModel(
        candidates: { AppState.shared.browserService.customViewCandidates() },
        prepareSources: { AppState.shared.browserService.prepareCustomViewSources() },
        sourcesDidChange: AppState.shared.browserService.customViewSourcesDidChange.eraseToAnyPublisher(),
        semanticFilter: .shared
    )

    /// Nil until the active view has been evaluated at least once (the UI
    /// shows nothing rather than a premature "No items" state).
    @Published private(set) var snapshot: Snapshot?
    /// The AI filter's progress / paused banner for the active view.
    @Published private(set) var semanticStatus: CustomViewSemanticStatus?
    private(set) var activeViewID: UUID?
    /// Nil = views' AI prompts are ignored (tests of the structured path).
    let semanticFilter: CustomViewSemanticFilter?

    /// The in-flight evaluation, exposed for tests to await.
    private(set) var refreshTask: Task<Void, Never>?

    private let candidates: @MainActor () -> [BrowserSearchResult]
    private let prepareSources: @MainActor () -> Void
    private let customViewStore: CustomViewStore
    private let emptySourcesGrace: TimeInterval
    private var generation = 0
    private var revision = 0
    private var activatedAt: Date = .distantPast
    /// A snapshot with rows was published since activation (the next one
    /// with rows is the page's "first results" — see `Snapshot.isInitial`).
    private var hasPublishedRows = false
    /// Minimum gap between progressive (per AI batch) row publishes.
    private let progressiveInterval: TimeInterval
    private var graceRetryTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "CustomViewPage")

    init(
        candidates: @escaping @MainActor () -> [BrowserSearchResult],
        prepareSources: @escaping @MainActor () -> Void = {},
        sourcesDidChange: AnyPublisher<Void, Never>,
        customViewStore: CustomViewStore = .shared,
        semanticFilter: CustomViewSemanticFilter? = nil,
        debounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(250),
        emptySourcesGrace: TimeInterval = 1.5,
        progressiveInterval: TimeInterval = 0.25
    ) {
        self.candidates = candidates
        self.prepareSources = prepareSources
        self.customViewStore = customViewStore
        self.semanticFilter = semanticFilter
        self.emptySourcesGrace = emptySourcesGrace
        self.progressiveInterval = progressiveInterval

        // Fires many times per cache refresh — coalesce.
        sourcesDidChange
            .debounce(for: debounce, scheduler: DispatchQueue.main)
            .sink { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.activeViewID != nil else { return }
                    self.refresh()
                }
            }
            .store(in: &cancellables)

        // The view's definition was edited (or deleted). `@Published` emits
        // in willSet, so hop once to read the stored value.
        customViewStore.$views
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.activeViewID != nil else { return }
                    self.refresh()
                }
            }
            .store(in: &cancellables)
    }

    /// Call with the active page's custom view id, or nil when the page is
    /// not showing (another view, or the bar is hidden).
    func activate(viewID: UUID?) {
        guard viewID != activeViewID else { return }
        activeViewID = viewID
        generation += 1
        refreshTask?.cancel()
        graceRetryTask?.cancel()
        snapshot = nil
        semanticStatus = nil
        hasPublishedRows = false
        guard viewID != nil else {
            // Queued AI batches of the view that was showing are dropped.
            semanticFilter?.setActive(prompt: nil)
            return
        }
        activatedAt = Date()
        // Forget AI verdicts of deleted views / edited prompts.
        semanticFilter?.pruneCache(keepingPrompts: customViewStore.views.filter(\.hasSemanticFilter).map(\.semanticPrompt))
        prepareSources()
        refresh()
    }

    /// Re-evaluates the active view now.
    func refresh() {
        guard let id = activeViewID else { return }
        guard let view = customViewStore.view(id: id) else {
            // Deleted while showing; `CommandBarViewStore` moves to Recents.
            snapshot = nil
            semanticStatus = nil
            semanticFilter?.setActive(prompt: nil)
            return
        }
        let semantic = view.hasSemanticFilter ? semanticFilter : nil
        // Synchronously, so batches queued for an edited prompt stop now.
        semanticFilter?.setActive(prompt: semantic == nil ? nil : view.semanticPrompt)
        let candidates = self.candidates()
        // Cold caches right after launch: an empty candidate list is "not
        // loaded yet", not "nothing matches" — wait for the sources (or the
        // grace period) instead of flashing the empty state.
        if candidates.isEmpty, Date().timeIntervalSince(activatedAt) < emptySourcesGrace {
            scheduleGraceRetry()
            return
        }

        generation += 1
        let gen = generation
        let now = Date()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let started = Date()
            let evaluated = await Task.detached(priority: .userInitiated) {
                CustomViewFilter.evaluate(view, candidates: candidates, now: now)
            }.value
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            guard let semantic else {
                self.semanticStatus = nil
                self.publish(view: view, items: evaluated, now: now)
                self.logger.debug("custom view evaluated \(candidates.count) candidates → \(evaluated.count) rows in \(Int(Date().timeIntervalSince(started) * 1000))ms")
                return
            }
            guard semantic.isAvailable else {
                self.semanticStatus = .paused
                self.publish(view: view, items: evaluated, now: now)
                return
            }
            await self.runSemantic(semantic, view: view, items: evaluated, now: now, generation: gen)
        }
    }

    /// Progressive AI pass: publishes rows when the matching set changes
    /// (throttled to `progressiveInterval`, the final state always), and the
    /// status line on every update.
    private func runSemantic(
        _ semantic: CustomViewSemanticFilter,
        view: CustomView,
        items: [CustomViewItem],
        now: Date,
        generation gen: Int
    ) async {
        var lastIDs: [String]?
        var lastPublish = Date.distantPast
        await semantic.run(prompt: view.semanticPrompt, items: items) { progress in
            guard !Task.isCancelled, self.generation == gen else { return }
            let ids = progress.included.map(\.id)
            if ids != lastIDs,
               lastIDs == nil || progress.isFinished || Date().timeIntervalSince(lastPublish) >= self.progressiveInterval {
                lastIDs = ids
                lastPublish = Date()
                self.publish(view: view, items: progress.included, now: now)
            }
            let status = CustomViewSemanticStatus(progress: progress)
            if self.semanticStatus != status { self.semanticStatus = status }
        }
    }

    private func publish(view: CustomView, items: [CustomViewItem], now: Date) {
        // Row ids must be unique for the list and keyboard selection.
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        let sections = CustomViewGrouping.sections(items: unique, groupBy: view.groupBy, now: now)
        var offsets: [Int] = []
        var flat: [CustomViewItem] = []
        flat.reserveCapacity(unique.count)
        for section in sections {
            offsets.append(flat.count)
            flat.append(contentsOf: section.items)
        }
        revision += 1
        // "Initial" until the page first has rows: an AI-filtered page may
        // start empty and fill in batch by batch.
        let isInitial = !hasPublishedRows
        if !flat.isEmpty { hasPublishedRows = true }
        snapshot = Snapshot(
            viewID: view.id,
            sections: sections,
            sectionOffsets: offsets,
            items: flat,
            revision: revision,
            isInitial: isInitial
        )
    }

    private func scheduleGraceRetry() {
        guard graceRetryTask == nil else { return }
        let delay = max(0.05, emptySourcesGrace - Date().timeIntervalSince(activatedAt))
        graceRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.graceRetryTask = nil
            self.refresh()
        }
    }
}
