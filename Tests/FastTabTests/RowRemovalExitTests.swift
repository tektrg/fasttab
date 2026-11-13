import Foundation
import Combine
import Testing
@testable import FastTab

@Suite struct RowRemovalExitTests {
    @Test func dismissedRowStaysOffscreenUntilFinished() {
        var exit = RowRemovalExit()
        #expect(exit.begin("a") == nil)
        #expect(exit.isExiting("a"))
        // Removing the row from the list must not bring it back: still exiting.
        #expect(exit.isExiting("a"))
        #expect(exit.finish("a", stillListed: false) == false)
        #expect(!exit.isExiting("a"))
    }

    @Test func failedCloseSlidesRowBack() {
        var exit = RowRemovalExit()
        _ = exit.begin("a")
        #expect(exit.finish("a", stillListed: true) == true)
        #expect(!exit.isExiting("a"))
    }

    @Test func newerRemovalSupersedesAndIsNotClearedByOldTask() {
        var exit = RowRemovalExit()
        _ = exit.begin("a")
        #expect(exit.begin("b") == "a")
        #expect(exit.finish("a", stillListed: false) == false)
        #expect(exit.isExiting("b"))
    }

    @Test func sameRowAgainIsNotSuperseded() {
        var exit = RowRemovalExit()
        _ = exit.begin("a")
        #expect(exit.begin("a") == nil)
    }
}

/// 2026-11-13 regression: "still snaps back". Pages draw from different
/// lists. Recents/search drop a removed row at once, but a custom view
/// re-evaluates its own list later (debounced, off the main thread), so the row
/// was still drawn when its exit slide was released: it slid back, then
/// vanished. A removed row must leave every page at the same moment.
@MainActor
@Suite struct RowRemovalAcrossPagesTests {
    static func row(_ n: Int) -> BrowserSearchResult {
        CustomViewFilterTests.item(.tab, "https://site\(n).example/p", title: "Row \(n)", ago: TimeInterval(60 * n))
    }

    @Test func removedRowLeavesEveryPageAtOnce() {
        var exit = RowRemovalExit()
        let items = (1...3).map { CommandBarDisplayItem.result(Self.row($0)) } + [.showAllTabs(count: 9)]
        let now = Date()
        _ = exit.begin(Self.row(2).id)
        exit.hide(Self.row(2).id, now: now)
        #expect(exit.visible(items, now: now).map(\.id) == [Self.row(1).id, Self.row(3).id, "command-bar-show-all-tabs"])
    }

    @Test func pinnedStackSlotsAreNeverHidden() {
        var exit = RowRemovalExit()
        let slot = OrderedTabSlot(url: "https://site1.example/p", title: "Row 1", browserName: "Google Chrome", isPinned: true)
        let items: [CommandBarDisplayItem] = [.orderedEntry(slot)]
        exit.hide(slot.asSearchResult.id, now: Date())
        #expect(exit.visible(items, now: Date()).count == 1)
    }

    /// A close that really failed: the row is still in its page's list after
    /// the hide runs out, so it shows again, at rest.
    @Test func rowStillListedAfterTheHoldComesBack() {
        var exit = RowRemovalExit()
        let items = [CommandBarDisplayItem.result(Self.row(1))]
        let removedAt = Date()
        exit.hide(Self.row(1).id, now: removedAt)
        #expect(exit.visible(items, now: removedAt.addingTimeInterval(RowRemovalExit.hideDuration - 0.1)).isEmpty)
        #expect(exit.visible(items, now: removedAt.addingTimeInterval(RowRemovalExit.hideDuration + 0.1)).count == 1)
    }

    @Test func expiredHidesArePrunedOnTheNextRemoval() {
        var exit = RowRemovalExit()
        let start = Date()
        exit.hide("a", now: start)
        exit.hide("b", now: start.addingTimeInterval(RowRemovalExit.hideDuration + 1))
        #expect(exit.hiddenIDs == ["b"])
    }

    /// Stack's "Sent to Mac" rows and custom-view rows are not in the Recents
    /// list; a trackpad swipe must find them in what the page draws, or the
    /// row springs back and nothing is removed.
    @Test func swipeFindsTheRowTheActivePageDraws() {
        let slot = OrderedTabSlot(url: "https://pinned.example", title: "Pinned", browserName: "Google Chrome", isPinned: true)
        let sent = Self.row(7)
        let stackPage: [CommandBarDisplayItem] = [.orderedEntry(slot), .result(sent)]
        #expect(stackPage.drawnResult(id: sent.id)?.id == sent.id)
        #expect(stackPage.drawnResult(id: slot.asSearchResult.id) == nil)
    }

    /// The real custom-view page model: its list still holds the removed row
    /// right after the remove (it re-evaluates later), but the page draws
    /// without it from the start, and still after the model catches up.
    @Test func customViewPageDropsTheRowBeforeItsListCatchesUp() async throws {
        let view = CustomView(name: "All")
        let suite = "test.fasttab.rowremoval.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CustomViewStore(defaults: defaults)
        store.add(view)
        var results = (1...3).map(Self.row)
        let changed = PassthroughSubject<Void, Never>()
        let model = CustomViewPageModel(
            candidates: { results },
            sourcesDidChange: changed.eraseToAnyPublisher(),
            customViewStore: store,
            emptySourcesGrace: 0
        )
        model.activate(viewID: view.id)
        await model.refreshTask?.value
        let removed = Self.row(2)
        func drawn(_ exit: RowRemovalExit) throws -> [String] {
            let items = try #require(model.snapshot).items.map { CommandBarDisplayItem.result($0.result) }
            return exit.visible(items, now: Date()).map(\.id)
        }

        var exit = RowRemovalExit()
        _ = exit.begin(removed.id)
        // What `BrowserTabService.remove` does to the page's sources.
        results.removeAll { $0.id == removed.id }
        changed.send()
        exit.hide(removed.id, now: Date())

        #expect(try #require(model.snapshot).items.contains { $0.result.id == removed.id })
        #expect(try !drawn(exit).contains(removed.id))

        try await Task.sleep(for: .milliseconds(400))
        await model.refreshTask?.value
        #expect(try #require(model.snapshot).items.allSatisfy { $0.result.id != removed.id })
        #expect(try !drawn(exit).contains(removed.id))
    }
}
