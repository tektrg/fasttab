import SwiftUI
import IndieCommandBar

/// Fast Tab's extra rows around the results ("Search the web", the
/// search-alias rows). Pure: which rows appear for which query and state. The
/// shared shell (`CommandBarActionRow`) draws them. An empty search adds none:
/// every tab is listed, with no "Show all tabs…" row (removed 2026-11-14).
struct FastTabExtraRows: CommandBarExtraRowsProvider {
    /// Alias mode is on: anything typed goes to this site.
    var activeSearchAlias: SearchAlias?
    /// The alias the current text would commit to on Tab/Space.
    var hintedSearchAlias: SearchAlias?

    func extraRows(for state: CommandBarListState) -> CommandBarExtraRows<CommandBarDisplayItem> {
        var extra = CommandBarExtraRows<CommandBarDisplayItem>()
        if !state.query.isEmpty, state.matchCount == 0, activeSearchAlias == nil {
            extra.trailing.append(.searchTheWeb(query: state.query))
        }
        if let activeSearchAlias {
            // Top of the list, so it is the default Enter target: the user
            // explicitly committed to this alias, and anything typed since is
            // meant for it rather than for the local index.
            extra.leading.append(.searchAliasQuery(alias: activeSearchAlias, query: state.query))
        } else if let hintedSearchAlias {
            // Bottom, and never auto-selected — a plain search for a word that
            // happens to be a keyword must not be hijacked.
            extra.trailing.append(.searchAliasHint(hintedSearchAlias))
        }
        return extra
    }

    /// The rows Recents (and a search on any page) lists: every result, uncapped,
    /// wrapped in the extra rows for `state`.
    func listItems(around results: [BrowserSearchResult], state: CommandBarListState) -> [CommandBarDisplayItem] {
        extraRows(for: state).assembled(around: results.map(CommandBarDisplayItem.result))
    }
}

extension CommandBarDisplayItem {
    /// The shared row model for Fast Tab's extra rows; nil for result rows,
    /// which draw themselves.
    func actionRow(
        webSearchBrowserName: String?,
        aliasTriggerKeys: Set<SearchAliasTriggerKey>
    ) -> CommandBarRow? {
        switch self {
        case .result, .orderedEntry:
            return nil
        case .searchTheWeb(let query):
            return CommandBarRow(
                id: id,
                title: "Search \u{201c}\(query)\u{201d}",
                subtitle: webSearchBrowserName.map { "Opens a new tab in \($0)" },
                subtitleSymbol: "globe",
                icon: "magnifyingglass"
            )
        case .searchAliasHint(let alias):
            // Worded as an instruction, not an action: this row does not open
            // anything, it switches the bar into alias mode.
            return CommandBarRow(
                id: id,
                title: "Search \(alias.displayName)",
                subtitle: Self.aliasTriggerHint(aliasTriggerKeys),
                subtitleSymbol: "keyboard",
                icon: "arrow.turn.down.right"
            )
        case .searchAliasQuery(let alias, let query):
            // The committed alias row: what Enter will actually open.
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return CommandBarRow(
                id: id,
                title: trimmedQuery.isEmpty
                    ? "Open \(alias.displayName)"
                    : "Search \(alias.displayName) for \u{201c}\(trimmedQuery)\u{201d}",
                subtitle: alias.origin.profileName.map { "\(alias.keyword) • \($0)" } ?? alias.keyword,
                subtitleSymbol: "arrow.up.forward.app",
                icon: "magnifyingglass"
            )
        }
    }

    static func aliasTriggerHint(_ triggerKeys: Set<SearchAliasTriggerKey>) -> String {
        let names = SearchAliasTriggerKey.allCases
            .filter { triggerKeys.contains($0) }
            .map(\.label)
        guard !names.isEmpty else { return "Enable a trigger key in Settings" }
        return "Press \(names.joined(separator: " or ")) to search this site"
    }
}
