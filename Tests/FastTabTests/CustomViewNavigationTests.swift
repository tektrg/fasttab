import Foundation
import Combine
import Testing
import CommandBarKit
@testable import FastTab

extension CommandBarViewStoreTests {
    /// A view store over isolated defaults + its own custom view store.
    @MainActor
    static func makeStore(
        customViews: [CustomView] = [],
        configure: (UserDefaults) -> Void = { _ in }
    ) -> (CommandBarViewStore, CustomViewStore, () -> Void) {
        let suiteName = "test.fasttab.viewstore.custom.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "onboarding.v1.completed")
        let customStore = CustomViewStore(defaults: defaults)
        for view in customViews { customStore.add(view) }
        configure(defaults)
        let store = CommandBarViewStore(defaults: defaults, customViewStore: customStore)
        return (store, customStore, { defaults.removePersistentDomain(forName: suiteName) })
    }
}

/// Generalized view identity (Recents → Stack → custom views → New View):
/// persistence/migration, ordering, deletion fallback, swipe + ⌘N navigation,
/// and sizing.
@MainActor
struct CustomViewNavigationTests {
    let work = CustomView(name: "Work", iconName: "briefcase")
    let reading = CustomView(name: "Reading")

    // MARK: Identity + persistence

    @Test func rawValuesKeepLegacyStringsAndRoundTrip() throws {
        #expect(CommandBarView.recents.rawValue == "recents")
        #expect(CommandBarView.stack.rawValue == "stack")
        let id = UUID()
        for view in [CommandBarView.recents, .stack, .custom(id), .newView] {
            #expect(CommandBarView(rawValue: view.rawValue) == view)
            let data = try JSONEncoder().encode(view)
            #expect(try JSONDecoder().decode(CommandBarView.self, from: data) == view)
        }
        // Codable stays the old single-string shape.
        #expect(String(decoding: try JSONEncoder().encode(CommandBarView.stack), as: UTF8.self) == "\"stack\"")
        #expect(CommandBarView(rawValue: "custom:not-a-uuid") == nil)
        #expect(CommandBarView(rawValue: "bogus") == nil)
    }

    @Test func persistedCustomDefaultsDecodeWhenTheViewExists() {
        let (store, _, cleanup) = CommandBarViewStoreTests.makeStore(customViews: [work]) { defaults in
            defaults.set("custom:\(self.work.id.uuidString)", forKey: CommandBarViewStore.defaultViewKey)
            defaults.set("custom:\(self.work.id.uuidString)", forKey: CommandBarViewStore.hoverDefaultViewKey)
        }
        defer { cleanup() }
        #expect(store.defaultView == .custom(work.id))
        #expect(store.activeView == .custom(work.id))
        #expect(store.hoverDefaultView == .custom(work.id))
    }

    @Test func missingCustomOrNewViewDefaultFallsBackToRecents() {
        let (store, _, cleanup) = CommandBarViewStoreTests.makeStore { defaults in
            defaults.set("custom:\(UUID().uuidString)", forKey: CommandBarViewStore.defaultViewKey)
            defaults.set("newView", forKey: CommandBarViewStore.hoverDefaultViewKey)
        }
        defer { cleanup() }
        #expect(store.defaultView == .recents)
        #expect(store.hoverDefaultView == .recents)
    }

    @Test func legacyRawValuesStillMigrate() {
        #expect(CommandBarViewStore.decodeView("myOrder", available: CommandBarView.builtins) == .stack)
        #expect(CommandBarViewStore.decodeView("bookmarks", available: CommandBarView.builtins) == .recents)
        #expect(CommandBarViewStore.decodeView("stack", available: CommandBarView.builtins) == .stack)
    }

    // MARK: Ordered list + deletion

    @Test func availableViewsFollowCustomViewStoreOrder() {
        let (store, customStore, cleanup) = CommandBarViewStoreTests.makeStore(customViews: [work, reading])
        defer { cleanup() }
        #expect(store.availableViews == [.recents, .stack, .custom(work.id), .custom(reading.id), .newView])
        #expect(store.selectableDefaultViews == [.recents, .stack, .custom(work.id), .custom(reading.id)])

        customStore.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(store.availableViews == [.recents, .stack, .custom(reading.id), .custom(work.id), .newView])
        #expect(store.index(of: .custom(reading.id)) == 2)
        #expect(store.index(of: .newView) == 4)
    }

    @Test func deletingActiveAndDefaultViewFallsBackToRecents() {
        let (store, customStore, cleanup) = CommandBarViewStoreTests.makeStore(customViews: [work, reading])
        defer { cleanup() }
        store.setDefaultView(.custom(work.id))
        store.setHoverDefaultView(.custom(work.id))
        store.selectView(.custom(work.id))
        #expect(store.activeView == .custom(work.id))

        customStore.delete(id: work.id)
        #expect(store.activeView == .recents)
        #expect(store.defaultView == .recents)
        #expect(store.hoverDefaultView == .recents)
        #expect(store.availableViews == [.recents, .stack, .custom(reading.id), .newView])
    }

    @Test func deletingAnotherViewKeepsTheActiveOne() {
        let (store, customStore, cleanup) = CommandBarViewStoreTests.makeStore(customViews: [work, reading])
        defer { cleanup() }
        store.selectView(.custom(reading.id))
        customStore.delete(id: work.id)
        #expect(store.activeView == .custom(reading.id))
    }

    @Test func selectViewUsesOrderForSlideDirectionAndIgnoresUnknownIDs() {
        let (store, _, cleanup) = CommandBarViewStoreTests.makeStore(customViews: [work, reading])
        defer { cleanup() }
        store.selectView(.custom(reading.id))
        #expect(store.slideDirection == .forward)
        store.selectView(.custom(work.id))
        #expect(store.slideDirection == .backward)
        store.selectView(.newView)
        #expect(store.slideDirection == .forward)

        store.selectView(.custom(UUID()))
        #expect(store.activeView == .newView)
        // New View can't be a default.
        store.setDefaultView(.newView)
        #expect(store.defaultView == .recents)
    }

    // MARK: Swipe

    @Test func flickWalksEveryPageAndClampsAtBothEnds() {
        let order: [CommandBarView] = [.recents, .stack, .custom(work.id), .custom(reading.id), .newView]
        var detector = ViewSwitchFlickDetector()
        var current = CommandBarView.recents
        var visited = [current]
        // Forward (leftward flicks) to the end.
        for _ in 0..<6 {
            if let next = detector.handleScroll(deltaX: -65, isEnded: false, currentView: current, orderedViews: order) {
                current = next
                visited.append(next)
            }
            _ = detector.handleScroll(deltaX: 0, isEnded: true, currentView: current, orderedViews: order)
        }
        #expect(visited == order)
        #expect(current == .newView)
        // Clamped: further forward flicks do nothing.
        #expect(detector.handleScroll(deltaX: -80, isEnded: false, currentView: .newView, orderedViews: order) == nil)

        // Back (rightward flicks) to the start.
        for _ in 0..<6 {
            if let next = detector.handleScroll(deltaX: 65, isEnded: false, currentView: current, orderedViews: order) {
                current = next
            }
            _ = detector.handleScroll(deltaX: 0, isEnded: true, currentView: current, orderedViews: order)
        }
        #expect(current == .recents)
        #expect(detector.handleScroll(deltaX: 80, isEnded: false, currentView: .recents, orderedViews: order) == nil)
    }

    @Test func oneGestureMovesOnlyOnePage() {
        let order: [CommandBarView] = [.recents, .stack, .custom(work.id), .newView]
        var detector = ViewSwitchFlickDetector()
        #expect(detector.handleScroll(deltaX: -70, isEnded: false, currentView: .stack, orderedViews: order) == .custom(work.id))
        // Same gesture keeps scrolling: suppressed until it ends.
        #expect(detector.handleScroll(deltaX: -70, isEnded: false, currentView: .custom(work.id), orderedViews: order) == nil)
    }

    @Test func flickFromAViewMissingFromTheOrderDoesNothing() {
        var detector = ViewSwitchFlickDetector()
        #expect(detector.handleScroll(deltaX: -80, isEnded: false, currentView: .custom(UUID()), orderedViews: [.recents, .stack, .newView]) == nil)
    }

    // MARK: ⌘N

    @Test func commandNumberMapsToNthPageExcludingNewView() {
        let order = CommandBarView.ordered(customViews: [work, reading])
        #expect(CommandBarView.numberedShortcutTarget(1, in: order) == .recents)
        #expect(CommandBarView.numberedShortcutTarget(2, in: order) == .stack)
        #expect(CommandBarView.numberedShortcutTarget(3, in: order) == .custom(work.id))
        #expect(CommandBarView.numberedShortcutTarget(4, in: order) == .custom(reading.id))
        #expect(CommandBarView.numberedShortcutTarget(5, in: order) == nil) // New View has no number
        #expect(CommandBarView.numberedShortcutTarget(0, in: order) == nil)

        let many = (0..<12).map { CustomView(name: "V\($0)") }
        let longOrder = CommandBarView.ordered(customViews: many)
        #expect(CommandBarView.numberedShortcutTarget(9, in: longOrder) == .custom(many[6].id))
        #expect(CommandBarView.numberedShortcutTarget(10, in: longOrder) == nil)
    }

    @Test func selectNumberedViewSwitchesAndReportsMisses() {
        let (store, _, cleanup) = CommandBarViewStoreTests.makeStore(customViews: [work])
        defer { cleanup() }
        #expect(store.selectNumberedView(3))
        #expect(store.activeView == .custom(work.id))
        #expect(store.selectNumberedView(4) == false)
        #expect(store.activeView == .custom(work.id))
    }

    @Test func headerTabsCarryShortcutNumbersAndNames() {
        let tabs = CommandBarViewTab.tabs(for: CommandBarView.ordered(customViews: [work]), customViews: [work])
        #expect(tabs.map(\.shortcutNumber) == [1, 2, 3, nil])
        #expect(tabs.map(\.title) == ["Search", "Stack", "Work", "New View"])
        #expect(tabs[2].icon == "briefcase")
        #expect(tabs[2].help == "Work (⌘3)")
        #expect(tabs[1].help == "Open Stack (⌘2)")
    }

    // MARK: Sizing

    @Test func customPagesAreTallLikeStackForSurfaceAndHitTest() {
        for anchor in CommandBarAnchor.allCases {
            for rowStyle in [ResultRowStyle.minimal, .full] {
                func rows(_ view: CommandBarView) -> Int {
                    // The one function both ContentView sizing and
                    // FastTabApp.isCursorOutsideSurface call.
                    CommandBarLayout.surfaceMaxRows(
                        view: view, isShowingAllOpenTabs: false, isSearching: false,
                        anchor: anchor, rowStyle: rowStyle, showFooter: true, quickOpenLimit: 5
                    )
                }
                let tall = CommandBarLayout.expandedAllTabsMaxRows(for: anchor, rowStyle: rowStyle, showFooter: true)
                #expect(rows(.stack) == tall)
                #expect(rows(.custom(UUID())) == tall)
                #expect(rows(.newView) == tall)
                #expect(rows(.recents) == 5)
            }
        }
    }
}

/// `CustomViewPageModel`: activation, debounced source refresh, the
/// post-filter hook, and grouping offsets.
@MainActor
struct CustomViewPageModelTests {
    final class Sources {
        var results: [BrowserSearchResult] = []
        let changed = PassthroughSubject<Void, Never>()
    }

    static func tab(_ url: String, title: String, ago: TimeInterval = 60) -> BrowserSearchResult {
        CustomViewFilterTests.item(.tab, url, title: title, ago: ago)
    }

    func makeModel(_ sources: Sources, store: CustomViewStore) -> CustomViewPageModel {
        CustomViewPageModel(
            candidates: { sources.results },
            sourcesDidChange: sources.changed.eraseToAnyPublisher(),
            customViewStore: store,
            debounce: .milliseconds(10),
            emptySourcesGrace: 0
        )
    }

    func makeStore(_ views: [CustomView]) -> (CustomViewStore, () -> Void) {
        let suite = "test.fasttab.customviewpage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = CustomViewStore(defaults: defaults)
        for v in views { store.add(v) }
        return (store, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func activationEvaluatesAndGroupsWithOffsets() async throws {
        let view = CustomView(name: "Dev", groupBy: .domain)
        let (store, cleanup) = makeStore([view])
        defer { cleanup() }
        let sources = Sources()
        sources.results = [
            Self.tab("https://github.com/a", title: "A", ago: 10),
            Self.tab("https://apple.com/b", title: "B", ago: 20),
            Self.tab("https://github.com/c", title: "C", ago: 30),
        ]
        let model = makeModel(sources, store: store)
        model.activate(viewID: view.id)
        await model.refreshTask?.value

        let snapshot = try #require(model.snapshot)
        #expect(snapshot.viewID == view.id)
        #expect(snapshot.isInitial)
        #expect(snapshot.sections.map(\.title) == ["github.com", "apple.com"])
        #expect(snapshot.sectionOffsets == [0, 2])
        #expect(snapshot.items.map(\.result.title) == ["A", "C", "B"])
    }

    @Test func publishedRowsRequestTheirFaviconsInDisplayOrderCapped() async throws {
        let view = CustomView(name: "All")
        let (store, cleanup) = makeStore([view])
        defer { cleanup() }
        let sources = Sources()
        sources.results = (0..<150).map { Self.tab("https://s\($0).example/p", title: "T\($0)", ago: TimeInterval(60 + $0)) } + [
            CustomViewFilterTests.item(.bookmark, "https://bm.example", title: "bm", ago: nil),
            CustomViewFilterTests.item(.history, "https://h.example", title: "hist", ago: 10),
        ]
        var requests: [[BrowserSearchResult]] = []
        let model = CustomViewPageModel(
            candidates: { sources.results },
            sourcesDidChange: sources.changed.eraseToAnyPublisher(),
            customViewStore: store,
            debounce: .milliseconds(10),
            emptySourcesGrace: 0,
            prefetchFavicons: { requests.append($0) },
            faviconPrefetchDelay: 0
        )
        model.activate(viewID: view.id)
        await model.refreshTask?.value
        try await Task.sleep(nanoseconds: 50_000_000)

        let snapshot = try #require(model.snapshot)
        let last = try #require(requests.last)
        #expect(requests.count == 1)
        #expect(last.count == CustomViewPageModel.faviconPrefetchLimit)
        #expect(last.map(\.id) == snapshot.items.prefix(CustomViewPageModel.faviconPrefetchLimit).map(\.result.id))
        #expect(last.first?.title == "hist") // history rows are included (newest first)

        // Leaving the page cancels a pending request.
        let countBefore = requests.count
        let slow = CustomViewPageModel(
            candidates: { sources.results },
            sourcesDidChange: sources.changed.eraseToAnyPublisher(),
            customViewStore: store,
            emptySourcesGrace: 0,
            prefetchFavicons: { requests.append($0) },
            faviconPrefetchDelay: 0.2
        )
        slow.activate(viewID: view.id)
        await slow.refreshTask?.value
        slow.activate(viewID: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(requests.count == countBefore)
    }

    @Test func sourceChangesRefreshTheActiveViewOnly() async throws {
        let view = CustomView(name: "All")
        let (store, cleanup) = makeStore([view])
        defer { cleanup() }
        let sources = Sources()
        sources.results = [Self.tab("https://a.com", title: "A")]
        let model = makeModel(sources, store: store)
        model.activate(viewID: view.id)
        await model.refreshTask?.value
        #expect(model.snapshot?.items.count == 1)

        sources.results.append(Self.tab("https://b.com", title: "B"))
        sources.changed.send()
        sources.changed.send()
        try await Task.sleep(nanoseconds: 80_000_000)
        await model.refreshTask?.value
        #expect(model.snapshot?.items.count == 2)
        #expect(model.snapshot?.isInitial == false)

        model.activate(viewID: nil)
        #expect(model.snapshot == nil)
        sources.changed.send()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.snapshot == nil)
    }

    @Test func withoutAnAIFilterEngineAPromptIsIgnored() async {
        let view = CustomView(name: "All", semanticPrompt: "Only keepers")
        let (store, cleanup) = makeStore([view])
        defer { cleanup() }
        let sources = Sources()
        sources.results = [Self.tab("https://a.com", title: "Keep"), Self.tab("https://b.com", title: "Drop")]
        let model = makeModel(sources, store: store)
        model.activate(viewID: view.id)
        await model.refreshTask?.value
        #expect(model.snapshot?.items.count == 2)
        #expect(model.semanticStatus == nil)
    }

    @Test func emptyMatchProducesEmptySnapshotNotNil() async {
        let view = CustomView(name: "None", domains: ["nowhere.example"])
        let (store, cleanup) = makeStore([view])
        defer { cleanup() }
        let sources = Sources()
        sources.results = [Self.tab("https://a.com", title: "A")]
        let model = makeModel(sources, store: store)
        model.activate(viewID: view.id)
        await model.refreshTask?.value
        #expect(model.snapshot?.items.isEmpty == true)
        #expect(model.snapshot?.sections.isEmpty == true)
    }
}
