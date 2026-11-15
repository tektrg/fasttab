import Foundation
import Testing
@testable import FastTab
import IndieCommandBar

/// Pins which extra rows ("Search the web", alias rows) appear for which query
/// and state, and what they say. An empty search adds none (no "Show all tabs…").
struct FastTabExtraRowsTests {
    private let jira = SearchAlias(
        keyword: "jira", displayName: "Service Desk",
        urlTemplate: "https://example.com/q?s={searchTerms}",
        origin: .browser(appName: "Microsoft Edge", profileName: "Work")
    )
    private let mine = SearchAlias(
        keyword: "gh", displayName: "GitHub",
        urlTemplate: "https://github.com/search?q=%s", origin: .user
    )

    private func ids(_ provider: FastTabExtraRows, _ query: String, active: Bool, matches: Int, results: [String] = []) -> [String] {
        let extra = provider.extraRows(for: CommandBarListState(query: query, isSearchActive: active, matchCount: matches))
        return extra.leading.map(\.id) + results + extra.trailing.map(\.id)
    }

    @Test func emptyQueryAddsNoExtraRows() {
        #expect(ids(FastTabExtraRows(), "", active: false, matches: 12, results: ["r"]) == ["r"])
        #expect(ids(FastTabExtraRows(), "", active: false, matches: 0).isEmpty)
    }

    @Test func searchTheWebOnlyWhenTypedTextMatchesNothing() {
        let p = FastTabExtraRows()
        #expect(ids(p, "zz", active: true, matches: 0) == ["command-bar-search-the-web"])
        #expect(ids(p, "zz", active: true, matches: 1).isEmpty)
        #expect(ids(p, "", active: true, matches: 0).isEmpty)
    }

    @Test func activeAliasGoesFirstAndSuppressesWebSearch() {
        let p = FastTabExtraRows(activeSearchAlias: jira, hintedSearchAlias: mine)
        #expect(ids(p, "bug", active: true, matches: 0, results: ["r"]) == ["command-bar-search-alias-query", "r"])
    }

    @Test func hintGoesLastAfterWebSearch() {
        let p = FastTabExtraRows(hintedSearchAlias: mine)
        #expect(ids(p, "gh", active: true, matches: 0) == ["command-bar-search-the-web", "command-bar-search-alias-hint"])
        #expect(ids(p, "gh", active: true, matches: 2, results: ["r"]) == ["r", "command-bar-search-alias-hint"])
    }

    @Test func extraRowsHaveAnActionRow() {
        let item = CommandBarDisplayItem.searchTheWeb(query: "q")
        #expect(item.actionRow(webSearchBrowserName: nil, aliasTriggerKeys: []) != nil)
    }

    @Test func rowTextIsUnchanged() {
        let web = CommandBarDisplayItem.searchTheWeb(query: "cats").actionRow(webSearchBrowserName: "Arc", aliasTriggerKeys: [])!
        #expect(web.title == "Search \u{201c}cats\u{201d}")
        #expect(web.subtitle == "Opens a new tab in Arc")
        #expect(CommandBarDisplayItem.searchTheWeb(query: "cats").actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [])!.subtitle == nil)

        let hint = CommandBarDisplayItem.searchAliasHint(mine)
        #expect(hint.actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [.tab, .space])!.subtitle == "Press Tab or Space to search this site")
        #expect(hint.actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [.space])!.subtitle == "Press Space to search this site")
        #expect(hint.actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [])!.subtitle == "Enable a trigger key in Settings")
        #expect(hint.actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [.tab])!.title == "Search GitHub")

        let open = CommandBarDisplayItem.searchAliasQuery(alias: jira, query: "  ").actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [])!
        #expect(open.title == "Open Service Desk")
        #expect(open.subtitle == "jira • Work")
        let search = CommandBarDisplayItem.searchAliasQuery(alias: mine, query: " x ").actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [])!
        #expect(search.title == "Search GitHub for \u{201c}x\u{201d}")
        #expect(search.subtitle == "gh")
    }

    @Test func resultOverlayShowsOnHoverOrSelectionAudibleOnHoverOnly() {
        #expect(CommandBarRowOverlayPolicy.isVisible(.hoverOrSelection, isHovering: false, isSelected: true))
        #expect(!CommandBarRowOverlayPolicy.isVisible(.hoverOnly, isHovering: false, isSelected: true))
    }
}
