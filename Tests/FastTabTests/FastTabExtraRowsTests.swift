import Foundation
import Testing
@testable import FastTab
import IndieCommandBar

/// Pins which extra rows ("Show all tabs…", "Search the web", alias rows)
/// appear for which query and state, and what they say.
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

    @Test func emptyQueryWithShowAllOffersOnlyShowAll() {
        let p = FastTabExtraRows(includesShowAllTabs: true)
        #expect(ids(p, "", active: false, matches: 12, results: ["r"]) == ["r", "command-bar-show-all-tabs"])
        if case .showAllTabs(let count) = p.extraRows(for: .init(query: "", isSearchActive: false, matchCount: 12)).trailing[0] {
            #expect(count == 12)
        } else { Issue.record("expected showAllTabs") }
    }

    @Test func showAllHiddenWhileSearchingOrWhenNotOffered() {
        #expect(ids(FastTabExtraRows(includesShowAllTabs: true), "x", active: true, matches: 3).isEmpty)
        #expect(ids(FastTabExtraRows(includesShowAllTabs: false), "", active: false, matches: 3).isEmpty)
    }

    @Test func searchTheWebOnlyWhenTypedTextMatchesNothing() {
        let p = FastTabExtraRows(includesShowAllTabs: false)
        #expect(ids(p, "zz", active: true, matches: 0) == ["command-bar-search-the-web"])
        #expect(ids(p, "zz", active: true, matches: 1).isEmpty)
        #expect(ids(p, "", active: true, matches: 0).isEmpty)
    }

    @Test func activeAliasGoesFirstAndSuppressesWebSearch() {
        let p = FastTabExtraRows(includesShowAllTabs: false, activeSearchAlias: jira, hintedSearchAlias: mine)
        #expect(ids(p, "bug", active: true, matches: 0, results: ["r"]) == ["command-bar-search-alias-query", "r"])
    }

    @Test func hintGoesLastAfterWebSearch() {
        let p = FastTabExtraRows(includesShowAllTabs: false, hintedSearchAlias: mine)
        #expect(ids(p, "gh", active: true, matches: 0) == ["command-bar-search-the-web", "command-bar-search-alias-hint"])
        #expect(ids(p, "gh", active: true, matches: 2, results: ["r"]) == ["r", "command-bar-search-alias-hint"])
    }

    @Test func extraRowsHaveAnActionRow() {
        let item = CommandBarDisplayItem.searchTheWeb(query: "q")
        #expect(item.actionRow(webSearchBrowserName: nil, aliasTriggerKeys: []) != nil)
    }

    @Test func rowTextIsUnchanged() {
        let one = CommandBarDisplayItem.showAllTabs(count: 1).actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [])!
        #expect(one.title == "Show all tabs...")
        #expect(one.subtitle == "1 open tab")
        #expect(one.icon == "rectangle.stack.fill")
        #expect(one.accessory != nil)
        #expect(CommandBarDisplayItem.showAllTabs(count: 3).actionRow(webSearchBrowserName: nil, aliasTriggerKeys: [])!.subtitle == "3 open tabs")

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
