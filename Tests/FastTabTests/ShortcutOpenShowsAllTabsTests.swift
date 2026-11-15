import Foundation
import CoreGraphics
import Testing
@testable import FastTab
import IndieCommandBar

/// Owner decision 2026-11-14: a keyboard-shortcut open looks like a mouse/hover open — every
/// tab, in the same tall panel (`expandedAllTabsMaxRows`, ~600pt, scrolls past it). No
/// "Quick-open items" cap, no "Show all tabs…" row.
struct ShortcutOpenShowsAllTabsTests {
    static func tabs(_ count: Int) -> [BrowserSearchResult] {
        (0..<count).map { index in
            BrowserSearchResult(
                title: "Tab \(index)",
                url: "https://example.com/\(index)",
                browserName: "Google Chrome",
                type: .tab,
                timestamp: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
                windowIndex: 1,
                tabIndex: index
            )
        }
    }

    static let emptySearch = CommandBarListState(query: "", isSearchActive: false, matchCount: 0)

    @Test(arguments: [0, 1, 5, 6, 50])
    func emptySearchListsEveryTabWithNoShowAllRow(count: Int) {
        let results = Self.tabs(count)
        var state = Self.emptySearch
        state.matchCount = count
        let items = FastTabExtraRows().listItems(around: results, state: state)
        #expect(items.map(\.id) == results.map(\.id))
        #expect(!items.map(\.id).contains("command-bar-show-all-tabs"))
    }

    @Test func recentsOnAnEmptySearchIsTheTallPanelAtEveryAnchor() {
        for anchor in CommandBarAnchor.allCases {
            for rowStyle in [ResultRowStyle.minimal, .full] {
                for showFooter in [true, false] {
                    let tall = CommandBarLayout.expandedAllTabsMaxRows(for: anchor, rowStyle: rowStyle, showFooter: showFooter)
                    let rows = CommandBarLayout.surfaceMaxRows(
                        view: .recents, isSearching: false, anchor: anchor, rowStyle: rowStyle, showFooter: showFooter
                    )
                    #expect(rows == tall)
                    // Typing a search shrinks to the short results panel only where the
                    // search box stays put (top-hugging positions); elsewhere it stays tall.
                    let searching = CommandBarLayout.surfaceMaxRows(
                        view: .recents, isSearching: true, anchor: anchor, rowStyle: rowStyle, showFooter: showFooter
                    )
                    #expect(searching == (CommandBarLayout.searchShrinksPanel(at: anchor)
                        ? Int(CommandBarLayout.visibleResultRows) : tall))
                }
            }
        }
    }

    /// Owner decision 2026-11-14: a search shrinks the panel only where it hugs the top
    /// (the search box stays still); at the side edges, centre and bottom corners the panel
    /// stays tall so the search box doesn't jump on the first keystroke.
    @Test func searchShrinksThePanelOnlyAtTopHuggingPositions() {
        let shrinks: [CommandBarAnchor] = [.notch, .corner(.topLeft), .corner(.topRight), .floating(.topCenter), .floating(.topLeft), .floating(.topRight)]
        let staysTall: [CommandBarAnchor] = [.bottomEdge, .leftEdge, .rightEdge, .corner(.bottomLeft), .corner(.bottomRight), .floating(.center), .floating(.bottomLeft), .floating(.bottomRight)]
        #expect(Set(shrinks + staysTall) == Set(CommandBarAnchor.allCases))
        for anchor in shrinks { #expect(CommandBarLayout.searchShrinksPanel(at: anchor)) }
        for anchor in staysTall {
            #expect(!CommandBarLayout.searchShrinksPanel(at: anchor))
            let tall = CommandBarLayout.expandedAllTabsMaxRows(for: anchor, rowStyle: .minimal, showFooter: true)
            #expect(CommandBarLayout.surfaceMaxRows(
                view: .recents, isSearching: true, anchor: anchor, rowStyle: .minimal, showFooter: true
            ) == tall)
        }
    }

    @Test func manyTabsDrawAtTheExpandedHeightAndNoTaller() {
        for anchor in CommandBarAnchor.allCases {
            for rowStyle in [ResultRowStyle.minimal, .full] {
                let maxRows = CommandBarLayout.surfaceMaxRows(
                    view: .recents, isSearching: false, anchor: anchor, rowStyle: rowStyle, showFooter: true
                )
                let fifty = CommandBarLayout.surfaceSize(for: anchor, rowStyle: rowStyle, rowCount: 50, maxRows: maxRows)
                let expanded = CommandBarLayout.surfaceSize(
                    for: anchor, rowStyle: rowStyle,
                    maxRows: CommandBarLayout.expandedAllTabsMaxRows(for: anchor, rowStyle: rowStyle)
                )
                #expect(fifty.height == expanded.height)
                #expect(fifty.height <= CommandBarLayout.expandedAllTabsMaxHeight)
            }
        }
    }

    /// The hover-dismiss box ("stay inside or the bar closes") must always contain the drawn
    /// panel, or leaving the box while still over the list closes the bar.
    @Test func hoverDismissBoxAlwaysContainsTheDrawnSurface() {
        let canvas = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let views: [CommandBarView] = [.recents, .stack, .custom(UUID()), .newView]
        for anchor in CommandBarAnchor.allCases {
            for rowStyle in [ResultRowStyle.minimal, .full] {
                for showFooter in [true, false] {
                    let defaults = Self.scratch()
                    defaults.set(rowStyle.rawValue, forKey: CommandBarAppearance.resultRowStyleKey)
                    defaults.set(showFooter, forKey: CommandBarAppearance.helperPanelVisibleKey)
                    for view in views {
                        let box = CommandBarLayout.surfaceFrame(
                            in: canvas, anchor: anchor, rowStyle: rowStyle,
                            maxRows: CommandBarLayout.hoverDismissMaxRows(view: view, anchor: anchor, defaults: defaults),
                            showFooter: showFooter
                        )
                        for searching in [false, true] {
                            let drawn = CommandBarLayout.surfaceFrame(
                                in: canvas, anchor: anchor, rowStyle: rowStyle,
                                maxRows: CommandBarLayout.surfaceMaxRows(
                                    view: view, isSearching: searching, anchor: anchor, rowStyle: rowStyle, showFooter: showFooter
                                ),
                                showFooter: showFooter
                            )
                            #expect(box.insetBy(dx: -0.5, dy: -0.5).contains(drawn),
                                    "box \(box) misses drawn \(drawn): \(anchor) \(view) \(rowStyle) footer=\(showFooter) searching=\(searching)")
                        }
                    }
                }
            }
        }
    }

    /// Stores from builds with the "Quick-open items" stepper still hold a count. It loads
    /// harmlessly and changes nothing: the panel and the hover box stay the tall list.
    @Test(arguments: [3, 5, 11, 15, 99, -1])
    func oldQuickOpenItemLimitValueIsIgnored(stored: Int) {
        let defaults = Self.scratch()
        defaults.set(stored, forKey: "FastTab.appearance.quickOpenItemLimit")
        _ = CommandBarAppearance.load(from: defaults)
        let tall = CommandBarLayout.expandedAllTabsMaxRows(for: .notch, rowStyle: .minimal, showFooter: true)
        #expect(CommandBarLayout.hoverDismissMaxRows(view: .recents, anchor: .notch, defaults: defaults) == tall)
    }

    static func scratch() -> UserDefaults {
        let name = "ShortcutOpenShowsAllTabsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
