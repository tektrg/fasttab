import AppKit
import IndieCommandBar
@testable import FastTab

/// The few lines of `ContentView` glue `ShortcutOpenRenderSheet` needs, for
/// THIS checkout's code: which rows Recents lists after a keyboard-shortcut
/// open, how many rows the panel is sized for, and the Settings › Shortcuts
/// caption. `ContentView` itself can't be built in a test (`AppState.shared`
/// starts CloudKit, which traps), so this mirrors its `listedItems` /
/// `resultsMaxRows` / `ShortcutsSettingsView` text and calls the same real
/// functions. Kept apart from the sheet so the sheet compiles on older
/// commits too: to render one, swap in that commit's glue (same three names).
@MainActor
enum ShortcutOpenRenderGlue {
    /// `ContentView.listedItems(for: .recents)` with no alias: every result,
    /// uncapped, plus the extra rows for the query.
    static func listItems(results: [BrowserSearchResult], query: String, rowStyle: ResultRowStyle) -> [CommandBarDisplayItem] {
        let isSearching = CommandBarLayout.isSearchActive(searchText: query, hasScopeChips: false, hasActiveAlias: false)
        return FastTabExtraRows(activeSearchAlias: nil, hintedSearchAlias: nil).listItems(
            around: results,
            state: CommandBarListState(query: query, isSearchActive: isSearching, matchCount: results.count)
        )
    }

    /// `ContentView.resultsMaxRows` on Recents.
    static func maxRows(query: String, anchor: CommandBarAnchor, rowStyle: ResultRowStyle, showFooter: Bool) -> Int {
        CommandBarLayout.surfaceMaxRows(
            view: .recents,
            isSearching: CommandBarLayout.isSearchActive(searchText: query, hasScopeChips: false, hasActiveAlias: false),
            anchor: anchor,
            rowStyle: rowStyle,
            showFooter: showFooter
        )
    }

    /// The caption under "Global shortcut" (nil where the page has none).
    static func shortcutCaption(modifiers: NSEvent.ModifierFlags, keyName: String) -> String? {
        ShortcutsSettingsView.backStepCaption(modifiers: modifiers, keyName: keyName)
    }
}
