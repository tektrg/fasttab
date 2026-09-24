import Foundation

enum CommandBarDisplayItem: Identifiable {
    case result(BrowserSearchResult)
    case orderedEntry(OrderedTabSlot)
    case showAllTabs(count: Int)
    case searchTheWeb(query: String)
    /// Offered when the typed text exactly names a search alias but the user
    /// hasn't committed to it yet — the discoverable half of "type a keyword,
    /// press Tab". Selecting it commits the alias, it does not open anything.
    case searchAliasHint(SearchAlias)
    /// Shown while alias mode is active: the row that actually opens the
    /// alias's site with whatever has been typed since.
    case searchAliasQuery(alias: SearchAlias, query: String)

    var id: String {
        switch self {
        case .result(let result):
            return result.id
        case .orderedEntry(let slot):
            return "ordered_\(slot.slotID.uuidString)"
        case .showAllTabs:
            return "command-bar-show-all-tabs"
        case .searchTheWeb:
            return "command-bar-search-the-web"
        case .searchAliasHint:
            return "command-bar-search-alias-hint"
        case .searchAliasQuery:
            return "command-bar-search-alias-query"
        }
    }

    var result: BrowserSearchResult? {
        switch self {
        case .result(let result):
            return result
        case .orderedEntry(let slot):
            return slot.asSearchResult
        default:
            return nil
        }
    }

    var isShowAllTabs: Bool {
        if case .showAllTabs = self { return true }
        return false
    }
}
