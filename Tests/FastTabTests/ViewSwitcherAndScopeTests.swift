import Foundation
import Testing
import IndieCommandBar
@testable import FastTab

/// Pins the view switcher and scope chips as they move onto IndieCommandBar.
struct ViewSwitcherAndScopeTests {
    @Test func tabIDsRoundTripToPagesAndOnlyCustomViewsAreEditable() {
        let work = CustomView(name: "Work")
        let tabs = CommandBarViewTab.tabs(for: CommandBarView.ordered(customViews: [work]), customViews: [work])
        #expect(tabs.map(\.view) == [.recents, .stack, .custom(work.id), .newView])
        #expect(tabs.map(\.isEditable) == [false, false, true, false])
        #expect(tabs[0].symbol == "magnifyingglass")
        #expect(tabs[3].help == "New View")
    }

    @Test func contextMenuOffersEditAndDeleteOnCustomViewsOnly() {
        let work = CustomView(name: "Work")
        let tabs = CommandBarViewTab.tabs(for: CommandBarView.ordered(customViews: [work]), customViews: [work])
        #expect(FastTabViewMenu.actions(for: tabs[0]).isEmpty)
        #expect(FastTabViewMenu.actions(for: tabs[3]).isEmpty)
        let menu = FastTabViewMenu.actions(for: tabs[2])
        #expect(menu.map(\.title) == ["Edit View…", "Delete View…"])
        #expect(menu.map(\.role) == [.normal, .destructive])
    }

    @Test func scopeParserModes() {
        func kind(_ text: String) -> String {
            switch ScopeSuggestionParser.mode(for: text) {
            case .hidden: return "hidden"
            case .root(let p, _): return "root:\(p)"
            case .bookmarks(let p, _): return "bookmarks:\(p)"
            case .history(let p, _): return "history:\(p)"
            }
        }
        #expect(kind("") == "hidden")
        #expect(kind("react") == "hidden")
        #expect(kind("@") == "root:")
        #expect(kind("react @Win") == "root:Win")
        #expect(kind("@Bookmarks:dev") == "bookmarks:dev")
        #expect(kind("x @HISTORY:to") == "history:to")
        #expect(kind("a@b") == "hidden")
        #expect(kind("@b more") == "hidden")
        if case .root(_, let range) = ScopeSuggestionParser.mode(for: "react @Win") {
            #expect(String("react @Win"[range]) == "@Win")
        } else {
            Issue.record("expected root")
        }
    }

    @Test func dropdownRowsCarryLabelSymbolDetail() {
        let s = ScopeSuggestion.root(.history).commandBarScope
        #expect(s.title == "History")
        #expect(s.symbol == "clock.arrow.circlepath")
        #expect(s.detail == "Search history")
        #expect(ScopeSuggestion.historyTime(.today).commandBarScope.detail == nil)
    }
}
