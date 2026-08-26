import Foundation
import OSLog

/// Owns the search-alias catalog: aliases the user defined in FastTab, plus a
/// periodically-refreshed import of the browsers' own address-bar search
/// engines, merged into one lookup the command bar queries per keystroke.
///
/// Browser-imported aliases are deliberately not editable here — the browser
/// owns them, and editing them there makes the change sync to the user's other
/// machines. Settings shows them read-only and points at the browser.
@MainActor
final class SearchAliasStore: ObservableObject {
    static let shared = SearchAliasStore()

    private static let userAliasesKey = "FastTab.searchAliases.user.v1"
    private static let triggerKeysKey = "FastTab.searchAliases.triggerKeys.v1"

    /// Aliases the user created in FastTab Settings.
    @Published private(set) var userAliases: [SearchAlias] = []
    /// Aliases mirrored from the browsers' `keywords` tables. Replaced wholesale
    /// on each import.
    @Published private(set) var importedAliases: [SearchAlias] = []
    /// Which keypresses commit a typed keyword into alias mode. Defaults to
    /// both: Tab is the browser convention, Space is what most people try.
    @Published private(set) var triggerKeys: Set<SearchAliasTriggerKey>

    /// User aliases layered over imported ones — what the command bar matches
    /// against. Recomputed on change rather than cached: the catalog is tens of
    /// entries, and a stale cache here would be a confusing class of bug.
    var allAliases: [SearchAlias] {
        SearchAliasMatching.merged(userAliases: userAliases, browserAliases: importedAliases)
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "SearchAliasStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.triggerKeys = Self.loadTriggerKeys(from: defaults)
        self.userAliases = Self.loadUserAliases(from: defaults)
    }

    // MARK: - Lookup

    /// The alias a Tab/Space press would commit for `text`, or nil.
    func alias(committedBy text: String) -> SearchAlias? {
        SearchAliasMatching.alias(committedBy: text, in: allAliases)
    }

    func isTriggerEnabled(_ key: SearchAliasTriggerKey) -> Bool {
        triggerKeys.contains(key)
    }

    // MARK: - Mutation

    func setTrigger(_ key: SearchAliasTriggerKey, enabled: Bool) {
        var next = triggerKeys
        if enabled { next.insert(key) } else { next.remove(key) }
        guard next != triggerKeys else { return }
        triggerKeys = next
        defaults.set(next.map(\.rawValue).sorted(), forKey: Self.triggerKeysKey)
    }

    /// Adds or replaces a user alias. Returns false when the input can't make a
    /// working alias, so Settings can show an inline error instead of silently
    /// storing something that will never fire.
    @discardableResult
    func upsertUserAlias(keyword: String, displayName: String, urlTemplate: String) -> Bool {
        let candidate = SearchAlias(
            keyword: keyword,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? keyword
                : displayName,
            urlTemplate: urlTemplate,
            origin: .user
        )
        guard !candidate.keyword.isEmpty,
              SearchAliasTemplate.containsQueryPlaceholder(candidate.urlTemplate),
              candidate.isOpenable
        else { return false }

        var next = userAliases.filter { $0.keyword != candidate.keyword }
        next.append(candidate)
        userAliases = next.sorted { $0.keyword.localizedCompare($1.keyword) == .orderedAscending }
        persistUserAliases()
        return true
    }

    func removeUserAlias(keyword: String) {
        let target = keyword.lowercased()
        guard userAliases.contains(where: { $0.keyword == target }) else { return }
        userAliases.removeAll { $0.keyword == target }
        persistUserAliases()
    }

    func replaceImportedAliases(_ aliases: [SearchAlias]) {
        guard aliases != importedAliases else { return }
        importedAliases = aliases
        logger.info("imported search aliases refreshed. count=\(aliases.count)")
    }

    // MARK: - Persistence

    /// Stored as a flat dictionary array rather than `Codable` structs so a
    /// future field addition can't fail to decode the whole list and silently
    /// wipe the user's aliases.
    private func persistUserAliases() {
        let encoded: [[String: Any]] = userAliases.map {
            ["keyword": $0.keyword, "displayName": $0.displayName, "urlTemplate": $0.urlTemplate]
        }
        defaults.set(encoded, forKey: Self.userAliasesKey)
    }

    private static func loadUserAliases(from defaults: UserDefaults) -> [SearchAlias] {
        guard let raw = defaults.array(forKey: userAliasesKey) as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let keyword = entry["keyword"] as? String,
                  let urlTemplate = entry["urlTemplate"] as? String
            else { return nil }
            return SearchAlias(
                keyword: keyword,
                displayName: (entry["displayName"] as? String) ?? keyword,
                urlTemplate: urlTemplate,
                origin: .user
            )
        }
        .sorted { $0.keyword.localizedCompare($1.keyword) == .orderedAscending }
    }

    private static func loadTriggerKeys(from defaults: UserDefaults) -> Set<SearchAliasTriggerKey> {
        guard let raw = defaults.array(forKey: triggerKeysKey) as? [String] else {
            return Set(SearchAliasTriggerKey.allCases)
        }
        let restored = Set(raw.compactMap(SearchAliasTriggerKey.init(rawValue:)))
        // An empty stored set is a deliberate "disable the feature", not a
        // decode failure — only fall back when the key was absent entirely.
        return restored
    }
}
