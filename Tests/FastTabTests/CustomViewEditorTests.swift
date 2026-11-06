import Foundation
import Combine
import Testing
import CommandBarKit
@testable import FastTab

/// Slice 3 — the view builder: draft validation + normalization, the filter
/// summary shown in Settings › Views, profile chips, the live match count,
/// the bar presenter's state machine, and reorder from Settings.
@MainActor
struct CustomViewEditorTests {
    static let day: TimeInterval = 86_400

    private func item(_ type: BrowserResultType, _ url: String, profile: String? = nil, browser: String = "Google Chrome") -> BrowserSearchResult {
        CustomViewFilterTests.item(type, url, profile: profile, browser: browser)
    }

    // MARK: Draft validation

    @Test func newDraftShowsEverythingAndNeedsOnlyAName() {
        var draft = CustomViewDraft()
        #expect(draft.types == CustomView.allowedTypes)
        #expect(draft.iconName == CustomView.defaultIconName)
        #expect(draft.issues == [.nameRequired])
        #expect(draft.savableView == nil)

        draft.name = "   "
        #expect(draft.issues == [.nameRequired])
        draft.name = "  Reading  "
        #expect(draft.isValid)
        #expect(draft.savableView?.name == "Reading")
    }

    @Test func atLeastOneTypeIsRequired() {
        var draft = CustomViewDraft()
        draft.name = "x"
        draft.types = []
        #expect(draft.issues == [.noTypes])
        draft.types = [.history]
        #expect(draft.isValid)
        #expect(draft.savableView?.effectiveTypes == [.history])
    }

    @Test func domainsAreNormalizedDedupedAndInvalidOnesReported() {
        var draft = CustomViewDraft()
        draft.name = "Dev"
        draft.domainsText = "https://www.GitHub.com/x, *.google.com\ngithub.com;docs.rs"
        #expect(draft.invalidDomains.isEmpty)
        #expect(draft.normalizedDomains == ["github.com", "google.com", "docs.rs"])
        #expect(draft.savableView?.domains == ["github.com", "google.com", "docs.rs"])

        draft.domainsText = "github.com, https://, exa$mple.com, *."
        #expect(draft.invalidDomains == ["https://", "exa$mple.com", "*."])
        #expect(draft.issues == [.invalidDomains(["https://", "exa$mple.com", "*."])])
        #expect(draft.savableView == nil)
        // The live count still previews the valid part.
        #expect(draft.previewView.domains == ["github.com"])
    }

    @Test func draftRoundTripsASavedView() {
        let saved = CustomView(
            name: "Work",
            iconName: "briefcase",
            types: [],
            profiles: ["Work", "work", " "],
            domains: ["jira.example.com"],
            keywords: " sprint ",
            lastVisited: .within(7 * Self.day),
            semanticPrompt: "tickets",
            groupBy: .domain
        )
        let draft = CustomViewDraft(view: saved)
        // Empty (= all) types show as all ticked.
        #expect(draft.types == CustomView.allowedTypes)
        #expect(draft.domainsText == "jira.example.com")
        let resaved = try! #require(draft.savableView)
        #expect(resaved.id == saved.id)
        #expect(resaved.profiles == ["Work"])
        #expect(resaved.keywords == "sprint")
        #expect(resaved.lastVisited == saved.lastVisited)
        #expect(resaved.groupBy == .domain)
        #expect(resaved.semanticPrompt == "tickets")
    }

    @Test func profileToggleIsCaseInsensitive() {
        var draft = CustomViewDraft()
        draft.toggleProfile("Work")
        #expect(draft.isProfileSelected("work"))
        draft.toggleProfile("WORK")
        #expect(draft.profiles.isEmpty)
    }

    // MARK: Summary

    @Test func filterSummaryListsOnlyConstrainedFields() {
        #expect(CustomView(name: "a").filterSummary == "All tabs, bookmarks and history")
        #expect(CustomView(name: "a", types: Set(CustomView.allowedTypes)).filterSummary == "All tabs, bookmarks and history")

        let view = CustomView(
            name: "Dev",
            types: [.tab],
            domains: ["https://www.github.com/x"],
            lastVisited: .within(7 * Self.day),
            semanticPrompt: "code reviews"
        )
        #expect(view.filterSummary == "Tabs · github.com · Within 7 days · AI")

        let busy = CustomView(
            name: "b",
            types: [.history, .bookmark],
            profiles: ["A", "B", "C"],
            domains: ["a.com", "b.com", "www.a.com"],
            keywords: "rust async",
            lastVisited: .olderThan(30 * Self.day)
        )
        #expect(busy.filterSummary == "Bookmarks + History · 3 profiles · a.com +1 · “rust async” · Older than 30 days")
        #expect(CustomView(name: "c", profiles: ["Work", "Home"]).filterSummary == "Work, Home")
    }

    // MARK: Profile chips

    @Test func profileOptionsMergeByNameAndNameBrowsersWhenAmbiguous() {
        let single = CustomViewProfileOption.options(
            from: [item(.tab, "https://a.com", profile: "Work"), item(.history, "https://b.com", profile: "work")],
            selected: []
        )
        #expect(single.map(\.label) == ["Work"])

        let mixed = CustomViewProfileOption.options(
            from: [
                item(.tab, "https://a.com", profile: "Default", browser: "Google Chrome"),
                item(.tab, "https://b.com", profile: "Default", browser: "Arc"),
                item(.bookmark, "https://c.com", profile: "Work", browser: "Google Chrome"),
                item(.tab, "https://d.com", profile: nil),
            ],
            selected: ["Gone"]
        )
        #expect(mixed.map(\.label) == ["Default · Arc, Google Chrome", "Gone", "Work · Google Chrome"])
    }

    // MARK: Live count

    @Test func previewCountsStructuredMatches() async {
        let candidates = [
            item(.tab, "https://github.com/a"),
            item(.bookmark, "https://github.com/b"),
            item(.history, "https://example.com"),
        ]
        let preview = CustomViewEditorPreview(
            candidates: { candidates },
            sourcesDidChange: Empty().eraseToAnyPublisher(),
            debounceNanoseconds: 1_000_000
        )
        var draft = CustomViewDraft()
        preview.update(draft: draft)
        await preview.pendingCount?.value
        #expect(preview.matchCount == 3)

        draft.domainsText = "github.com"
        preview.update(draft: draft)
        await preview.pendingCount?.value
        #expect(preview.matchCount == 2)

        draft.types = [.tab]
        preview.update(draft: draft)
        await preview.pendingCount?.value
        #expect(preview.matchCount == 1)
    }

    // MARK: Last visited hint

    @Test func historyReachIsTheShortestPerSourceRoundedDown() {
        let now = CustomViewFilterTests.now
        let candidates = [
            // Chrome Work reaches 10.9 days, Chrome Personal 3.5, Safari 20.
            item(.history, "https://a.com", profile: "Work"),
            CustomViewFilterTests.item(.history, "https://b.com", ago: 10.9 * Self.day, profile: "Work"),
            CustomViewFilterTests.item(.history, "https://c.com", ago: 3.5 * Self.day, profile: "Personal"),
            CustomViewFilterTests.item(.history, "https://d.com", ago: 20 * Self.day, browser: "Safari"),
            // Not history, or a sentinel timestamp: ignored.
            CustomViewFilterTests.item(.bookmark, "https://e.com", ago: 1 * Self.day, profile: "Personal"),
            CustomViewFilterTests.item(.tab, "https://f.com", ago: 0.5 * Self.day, browser: "Safari"),
            CustomViewFilterTests.item(.history, "https://g.com", ago: nil, browser: "Arc"),
        ]
        #expect(CustomViewDraft.historyReachDays(candidates: candidates, now: now) == 3)

        let withoutPersonal = candidates.filter { $0.profileName != "Personal" }
        #expect(CustomViewDraft.historyReachDays(candidates: withoutPersonal, now: now) == 10)
    }

    @Test func historyReachIsAtLeastOneDayAndNilWithoutHistory() {
        let now = CustomViewFilterTests.now
        let fresh = [CustomViewFilterTests.item(.history, "https://a.com", ago: 3_600)]
        #expect(CustomViewDraft.historyReachDays(candidates: fresh, now: now) == 1)
        let noHistory = [item(.tab, "https://a.com"), item(.bookmark, "https://b.com")]
        #expect(CustomViewDraft.historyReachDays(candidates: noHistory, now: now) == nil)
        #expect(CustomViewDraft.historyReachDays(candidates: [], now: now) == nil)
    }

    @Test func lastVisitedHintText() {
        #expect(CustomViewDraft.lastVisitedHint(rule: .any, historyReachDays: 5) == nil)
        #expect(CustomViewDraft.lastVisitedHint(rule: .within(7 * Self.day), historyReachDays: 12)
                == "Based on your recent history (about 12 days).")
        #expect(CustomViewDraft.lastVisitedHint(rule: .within(Self.day), historyReachDays: 1)
                == "Based on your recent history (about 1 day).")
        #expect(CustomViewDraft.lastVisitedHint(rule: .within(Self.day), historyReachDays: nil)
                == "Based on recent history.")
        #expect(CustomViewDraft.lastVisitedHint(rule: .olderThan(30 * Self.day), historyReachDays: 12)
                == "Based on your recent history (about 12 days). Bookmarks not opened in that time are left out.")
        // The hint must describe what the filter does: an unknown last
        // visit never matches a time rule (owner decision), so such a
        // bookmark is excluded — not shown under "Unknown".
        let bookmark = CustomViewFilterTests.item(.bookmark, "https://old.example", title: "Old", ago: nil)
        #expect(CustomViewFilter.evaluate(CustomView(name: "Old", lastVisited: .olderThan(30 * Self.day)), candidates: [bookmark]).isEmpty)
    }

    @Test func previewPublishesHistoryReach() async {
        let candidates = [CustomViewFilterTests.item(.history, "https://a.com", ago: 5 * Self.day)]
        let preview = CustomViewEditorPreview(
            candidates: { candidates },
            sourcesDidChange: Empty().eraseToAnyPublisher(),
            debounceNanoseconds: 1_000_000,
            now: { CustomViewFilterTests.now }
        )
        #expect(preview.historyReachDays == nil)
        preview.update(draft: CustomViewDraft())
        #expect(preview.historyReachDays == 5)
    }

    // MARK: Presenter

    private func makePresenter(customViews: [CustomView] = []) -> (CustomViewEditorPresenter, CommandBarViewStore, CustomViewStore, () -> Void) {
        let (viewStore, store, cleanup) = CommandBarViewStoreTests.makeStore(customViews: customViews)
        return (CustomViewEditorPresenter(store: store, viewStore: viewStore), viewStore, store, cleanup)
    }

    @Test func newThenSaveAddsTheViewAndSwitchesToIt() {
        let (presenter, viewStore, store, cleanup) = makePresenter()
        defer { cleanup() }

        presenter.presentNew()
        #expect(presenter.request == .new)
        #expect(viewStore.activeView == .newView)
        #expect(presenter.isEditing(on: .newView))
        #expect(presenter.holdsBar)

        // Invalid (no name): stays open, nothing saved.
        #expect(!presenter.save())
        #expect(presenter.request == .new)
        #expect(store.views.isEmpty)

        presenter.draft.name = "Reading"
        presenter.draft.domainsText = "medium.com"
        #expect(presenter.save())
        let saved = try! #require(store.views.first)
        #expect(saved.name == "Reading")
        #expect(saved.domains == ["medium.com"])
        #expect(presenter.request == nil)
        #expect(viewStore.activeView == .custom(saved.id))
        #expect(viewStore.availableViews == [.recents, .stack, .custom(saved.id), .newView])
    }

    @Test func cancellingNewStaysOnTheNewViewPage() {
        let (presenter, viewStore, store, cleanup) = makePresenter()
        defer { cleanup() }
        presenter.presentNew()
        presenter.draft.name = "Draft"
        presenter.cancelTopmost()
        #expect(presenter.request == nil)
        #expect(viewStore.activeView == .newView)
        #expect(store.views.isEmpty)
        // Reopening starts from a fresh draft.
        presenter.presentNew()
        #expect(presenter.draft.name == "")
    }

    @Test func editSavesInPlace() {
        let work = CustomView(name: "Work", iconName: "briefcase")
        let (presenter, viewStore, store, cleanup) = makePresenter(customViews: [work])
        defer { cleanup() }

        presenter.presentEdit(id: work.id)
        #expect(presenter.request == .edit(work.id))
        #expect(viewStore.activeView == .custom(work.id))
        #expect(presenter.draft.name == "Work")

        presenter.draft.name = "Job"
        #expect(presenter.save())
        #expect(store.views.map(\.name) == ["Job"])
        #expect(store.views.first?.id == work.id)
        #expect(viewStore.activeView == .custom(work.id))
        #expect(presenter.request == nil)
    }

    @Test func editThenDeleteFallsBackToRecents() {
        let work = CustomView(name: "Work")
        let (presenter, viewStore, store, cleanup) = makePresenter(customViews: [work])
        defer { cleanup() }

        presenter.presentEdit(id: work.id)
        presenter.requestDelete(id: work.id)
        #expect(presenter.request == .edit(work.id))
        #expect(presenter.pendingDeleteID == work.id)

        // Esc backs out of the confirmation, not the editor.
        presenter.cancelTopmost()
        #expect(presenter.pendingDeleteID == nil)
        #expect(presenter.request == .edit(work.id))

        presenter.requestDelete(id: work.id)
        presenter.confirmDelete()
        #expect(store.views.isEmpty)
        #expect(presenter.request == nil)
        #expect(presenter.pendingDeleteID == nil)
        #expect(viewStore.activeView == .recents)
    }

    @Test func headerDeleteAsksFirst() {
        let work = CustomView(name: "Work")
        let reading = CustomView(name: "Reading")
        let (presenter, viewStore, store, cleanup) = makePresenter(customViews: [work, reading])
        defer { cleanup() }

        presenter.requestDelete(id: reading.id)
        #expect(store.views.count == 2)
        #expect(presenter.request == nil)
        #expect(viewStore.activeView == .custom(reading.id))
        #expect(presenter.holdsBar(on: .custom(reading.id)))
        #expect(!presenter.holdsBar(on: .custom(work.id)))

        presenter.cancelTopmost()
        #expect(store.views.count == 2)
        #expect(!presenter.holdsBar)

        presenter.requestDelete(id: reading.id)
        presenter.confirmDelete()
        #expect(store.views.map(\.id) == [work.id])
        #expect(viewStore.activeView == .recents)
    }

    @Test func leavingThePageOrHidingTheBarDiscardsTheDraft() {
        let work = CustomView(name: "Work")
        let (presenter, viewStore, store, cleanup) = makePresenter(customViews: [work])
        defer { cleanup() }

        presenter.presentEdit(id: work.id)
        presenter.draft.name = "Changed"
        presenter.syncWith(activeView: viewStore.activeView, isBarVisible: true)
        #expect(presenter.request == .edit(work.id))

        viewStore.selectView(.stack)
        presenter.syncWith(activeView: viewStore.activeView, isBarVisible: true)
        #expect(presenter.request == nil)
        #expect(store.views.first?.name == "Work")

        presenter.presentNew()
        presenter.syncWith(activeView: viewStore.activeView, isBarVisible: false)
        #expect(!presenter.holdsBar)
    }

    @Test func editingAMissingViewIsANoOp() {
        let (presenter, viewStore, _, cleanup) = makePresenter()
        defer { cleanup() }
        presenter.presentEdit(id: UUID())
        presenter.requestDelete(id: UUID())
        #expect(presenter.request == nil)
        #expect(presenter.pendingDeleteID == nil)
        #expect(viewStore.activeView == .recents)
    }

    // MARK: Settings reorder

    @Test func settingsReorderChangesSwipeOrder() {
        let a = CustomView(name: "A"), b = CustomView(name: "B"), c = CustomView(name: "C")
        let (_, viewStore, store, cleanup) = makePresenter(customViews: [a, b, c])
        defer { cleanup() }

        // Drag C to the top (List.onMove offsets).
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(store.views.map(\.name) == ["C", "A", "B"])
        #expect(viewStore.availableViews == [.recents, .stack, .custom(c.id), .custom(a.id), .custom(b.id), .newView])

        // Drag A below B.
        store.move(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        #expect(store.views.map(\.name) == ["C", "B", "A"])
    }
}
