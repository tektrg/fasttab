import Foundation
import Combine
import OSLog

/// Optional asynchronous pass over a custom view's structurally-filtered
/// items, run before grouping. Slice 4 (semantic / Foundation Models filter)
/// plugs in here via `CustomViewPageModel.postFilter`; it receives the items
/// already sorted and must return a subset (order is preserved by grouping).
typealias CustomViewPostFilter = @Sendable (CustomView, [CustomViewItem]) async -> [CustomViewItem]

/// What the custom view page currently shows: the active view's matching
/// items, grouped. Owns re-evaluation — on activation, when the view's
/// definition changes, and (debounced) whenever the underlying tab /
/// bookmark / history caches change.
///
/// Pipeline (`refresh`): `CustomViewFilter.evaluate` (off the main thread) →
/// `postFilter` (async hook, nil today) → `CustomViewGrouping.sections` →
/// publish `snapshot`. A newer refresh supersedes an in-flight one.
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
        /// First snapshot since the view was activated.
        let isInitial: Bool
    }

    static let shared = CustomViewPageModel(
        candidates: { AppState.shared.browserService.customViewCandidates() },
        prepareSources: { AppState.shared.browserService.prepareCustomViewSources() },
        sourcesDidChange: AppState.shared.browserService.customViewSourcesDidChange.eraseToAnyPublisher()
    )

    /// Nil until the active view has been evaluated at least once (the UI
    /// shows nothing rather than a premature "No items" state).
    @Published private(set) var snapshot: Snapshot?
    private(set) var activeViewID: UUID?
    /// Slice-4 hook: see `CustomViewPostFilter`.
    var postFilter: CustomViewPostFilter?

    /// The in-flight evaluation, exposed for tests to await.
    private(set) var refreshTask: Task<Void, Never>?

    private let candidates: @MainActor () -> [BrowserSearchResult]
    private let prepareSources: @MainActor () -> Void
    private let customViewStore: CustomViewStore
    private let emptySourcesGrace: TimeInterval
    private var generation = 0
    private var revision = 0
    private var activatedAt: Date = .distantPast
    private var graceRetryTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "CustomViewPage")

    init(
        candidates: @escaping @MainActor () -> [BrowserSearchResult],
        prepareSources: @escaping @MainActor () -> Void = {},
        sourcesDidChange: AnyPublisher<Void, Never>,
        customViewStore: CustomViewStore = .shared,
        debounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(250),
        emptySourcesGrace: TimeInterval = 1.5
    ) {
        self.candidates = candidates
        self.prepareSources = prepareSources
        self.customViewStore = customViewStore
        self.emptySourcesGrace = emptySourcesGrace

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
        guard viewID != nil else { return }
        activatedAt = Date()
        prepareSources()
        refresh()
    }

    /// Re-evaluates the active view now.
    func refresh() {
        guard let id = activeViewID else { return }
        guard let view = customViewStore.view(id: id) else {
            // Deleted while showing; `CommandBarViewStore` moves to Recents.
            snapshot = nil
            return
        }
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
        let postFilter = self.postFilter
        let wasEmpty = snapshot == nil
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let started = Date()
            let evaluated = await Task.detached(priority: .userInitiated) {
                CustomViewFilter.evaluate(view, candidates: candidates, now: now)
            }.value
            guard !Task.isCancelled else { return }
            // ↓ Slice-4 insertion point (semantic filter), already async.
            var filtered = evaluated
            if let postFilter { filtered = await postFilter(view, evaluated) }
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.publish(view: view, items: filtered, now: now, isInitial: wasEmpty)
            self.logger.debug("custom view evaluated \(candidates.count) candidates → \(filtered.count) rows in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
    }

    private func publish(view: CustomView, items: [CustomViewItem], now: Date, isInitial: Bool) {
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

/// Where the custom view builder is opened from (New View page, a view's
/// header pill context menu, the empty state). Slice 3 implements the
/// builder by observing `request` (or replacing these two methods).
@MainActor
final class CustomViewEditorPresenter: ObservableObject {
    static let shared = CustomViewEditorPresenter()

    enum Request: Equatable {
        case new
        case edit(UUID)
    }

    /// The builder the UI should show; nil = none. Slice 3 clears it with
    /// `dismiss()` when the builder closes.
    @Published private(set) var request: Request?

    func presentNew() { request = .new }

    func presentEdit(id: UUID) { request = .edit(id) }

    func dismiss() { request = nil }
}
