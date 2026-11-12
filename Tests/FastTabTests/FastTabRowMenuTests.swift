import AppKit
import Foundation
import Testing
import IndieCommandBar
@testable import FastTab

/// Gap 7: the ⋯ menu lists the shared row actions; titles and order are the ones the old
/// hand-built menu showed (characterization), plus the standard copy action ⌘C runs.
@MainActor
struct FastTabRowMenuTests {
    private func result(_ type: BrowserResultType = .tab, browser: String = "Safari", url: String = "https://example.com/a",
                        pinned: Bool = false) -> BrowserSearchResult {
        BrowserSearchResult(title: "A", url: url, browserName: browser, type: type, timestamp: Date(),
                            windowIndex: 1, tabIndex: 1, isPinned: pinned)
    }

    private func slot(_ state: SlotState, browser: String = "Safari", pinned: Bool = false) -> OrderedTabSlot {
        OrderedTabSlot(url: "https://example.com/s", matchKey: "https://example.com/s", title: "S", browserName: browser,
                       profileName: nil, state: state, boundTabID: nil, isPinned: pinned, confirmedInBrowser: false)
    }

    private func titles(_ actions: [CommandBarRowAction]) -> [String] { actions.map(\.title) }

    @Test func liveTabMenuKeepsItsItems() {
        let r = result()
        let actions = FastTabRowMenu.actions(for: r, bridge: .sendToListAndClose, offersPin: true)
        #expect(titles(actions) == ["Open in Safari", "Send to FastTab List & Close (⌘S)", "Pin Tab", "Copy Link"])
        #expect(actions.copyAction?.title == "Copy Link")
    }

    @Test func pinnedTabSaysUnpinAndPinNeedsTheHook() {
        #expect(titles(FastTabRowMenu.actions(for: result(pinned: true), bridge: nil, offersPin: true))
                == ["Open in Safari", "Unpin Tab", "Copy Link"])
        #expect(titles(FastTabRowMenu.actions(for: result(), bridge: nil, offersPin: false)) == ["Open in Safari", "Copy Link"])
    }

    @Test func nonTabRowsHaveNoPinAndListItemsMoveToBookmarksWithCommandD() {
        #expect(titles(FastTabRowMenu.actions(for: result(.bookmark, browser: ""), bridge: .sendToList, offersPin: true))
                == ["Open Link", "Send to FastTab List (⌘S)", "Copy Link"])
        #expect(titles(FastTabRowMenu.actions(for: result(.fastTabList), bridge: .moveToBookmarks, offersPin: true))
                == ["Open in Safari", "Move to Bookmarks (⌘D)", "Copy Link"])
        #expect(titles(FastTabRowMenu.actions(for: result(.tab, browser: ""), bridge: nil, offersPin: false))
                == ["Switch to Tab", "Copy Link"])
    }

    @Test func stackSlotMenuKeepsItsItems() {
        #expect(titles(FastTabRowMenu.actions(for: slot(.live), bridge: .sendToListAndClose))
                == ["Open in Safari", "Send to FastTab List & Close (⌘S)", "Pin Tab", "Copy URL"])
        #expect(titles(FastTabRowMenu.actions(for: slot(.ghost, pinned: true), bridge: nil))
                == ["Reopen in Safari", "Unpin Tab", "Copy URL"])
        #expect(titles(FastTabRowMenu.actions(for: slot(.browserFrozen), bridge: nil)) == ["Open Link", "Pin Tab", "Copy URL"])
        #expect(FastTabRowMenu.actions(for: slot(.live), bridge: nil).copyAction?.title == "Copy URL")
    }

    // MARK: ⌘C / ⌘, routing

    private func route(_ keyCode: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = .command,
                       row: FastTabKeyRouting.SelectedRow = .liveTab, index: Int = 0, selection: Bool = false) -> FastTabKeyRouting.Action {
        var c = FastTabKeyRouting.Context()
        c.selectedIndex = index
        c.selectedRow = row
        c.hasTextSelection = selection
        return FastTabKeyRouting.route(keyCode: keyCode, characters: chars, modifiers: mods, context: c)
    }

    @Test func commandCCopiesTheHighlightedRow() {
        #expect(route(8, "c", row: .liveTab) == .copySelection)
        #expect(route(8, "c", row: .otherResult) == .copySelection)
        #expect(route(8, "c", row: .stackSlot) == .copySelection)
    }

    @Test func commandCLeavesTheSearchFieldAndExtraRowsAlone() {
        #expect(route(8, "c", row: .none, index: -1) == .passThrough)
        #expect(route(8, "c", row: .other) == .passThrough)
        #expect(route(8, "c", row: .liveTab, selection: true) == .passThrough)
        #expect(route(8, "c", [.command, .shift]) == .passThrough)
    }

    @Test func commandCommaOpensSettingsFromAnywhere() {
        #expect(route(43, ",", row: .none, index: -1) == .openSettings)
        #expect(route(43, ",", row: .liveTab) == .openSettings)
    }

    @Test func characterlessCallsKeepTheOldRouting() {
        // Characterization: without characters (old call shape) ⌘C / ⌘, were never claimed.
        var c = FastTabKeyRouting.Context()
        c.selectedIndex = 0
        c.selectedRow = .liveTab
        #expect(FastTabKeyRouting.route(keyCode: 8, modifiers: .command, context: c) == .passThrough)
        #expect(FastTabKeyRouting.route(keyCode: 43, modifiers: .command, context: c) == .passThrough)
    }
}
