import Foundation

// MARK: - Model

/// Where an alias came from.
///
/// `.browser` aliases mirror a Chromium profile's own search-engine table
/// (`Web Data` → `keywords`) and are read-only here: the browser owns them,
/// re-imports overwrite them, and editing belongs in the browser's own
/// settings so the change syncs to the user's other machines.
/// `.user` aliases are owned by FastTab and persist in `UserDefaults`.
enum SearchAliasOrigin: Equatable, Hashable, Sendable {
    case browser(appName: String, profileName: String)
    case user

    var browserAppName: String? {
        guard case .browser(let appName, _) = self else { return nil }
        return appName
    }

    var profileName: String? {
        guard case .browser(_, let profileName) = self else { return nil }
        return profileName
    }

    var isUserDefined: Bool { self == .user }
}

/// One "type a keyword, then search that site" entry — the same concept as a
/// browser's address-bar search engine.
///
/// The template does double duty: with a search endpoint (`/search?q=`) it
/// searches, and with a direct-lookup endpoint (Jira's `QuickSearch.jspa`) the
/// destination site resolves an exact record ID straight to that record. One
/// mechanism, both behaviours — the site decides which.
struct SearchAlias: Identifiable, Equatable, Hashable, Sendable {
    /// What the user types to trigger it (e.g. `jira`, `github.com`). Compared
    /// case-insensitively; stored lowercased.
    let keyword: String
    /// Human label for the row (e.g. "7-Eleven Service Desk").
    let displayName: String
    /// URL with a query placeholder — `{searchTerms}` (Chromium's own token)
    /// or `%s` (what browser settings screens display, so what users type).
    let urlTemplate: String
    let origin: SearchAliasOrigin
    /// The browser's own hit counter for this engine, used for ranking.
    /// Always 0 for user-defined aliases.
    let usageCount: Int

    init(
        keyword: String,
        displayName: String,
        urlTemplate: String,
        origin: SearchAliasOrigin,
        usageCount: Int = 0
    ) {
        self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.urlTemplate = urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        self.origin = origin
        self.usageCount = usageCount
    }

    var id: String {
        switch origin {
        case .user:
            return "user|\(keyword)"
        case .browser(let appName, let profileName):
            return "browser|\(appName)|\(profileName)|\(keyword)"
        }
    }

    /// Fills the placeholder with `query` and returns an openable absolute URL,
    /// or nil when the template can't produce one (see `SearchAliasTemplate`).
    func expandedURL(query: String) -> String? {
        SearchAliasTemplate.expand(urlTemplate, query: query)
    }

    /// True when the template is openable at all. Import filters on this so a
    /// broken entry never reaches the results list.
    var isOpenable: Bool {
        expandedURL(query: "fasttab probe") != nil
    }
}

// MARK: - Template expansion

/// Expands a browser search-engine URL template into a real URL.
///
/// Chromium templates are not plain `%s` strings — that is only what the
/// settings screen *displays*. The stored value uses `{searchTerms}` plus
/// optional and vendor-specific parameters, e.g.
/// `https://www.youtube.com/results?search_query={searchTerms}&page={startPage?}`.
enum SearchAliasTemplate {
    /// Placeholders that resolve to a fixed value rather than being dropped.
    /// Kept deliberately tiny: only tokens that actually appear in shipped
    /// prepopulated engines and would break the URL if simply removed.
    private static let literalSubstitutions: [String: String] = [
        "google:baseURL": "https://www.google.com/",
        "google:baseSuggestURL": "https://www.google.com/complete/",
        "bing:baseURL": "https://www.bing.com/",
        "inputEncoding": "UTF-8",
        "language": "en"
    ]

    /// The two spellings of "put the query here".
    private static let queryTokens = ["searchTerms", "google:searchTerms"]

    static func expand(_ template: String, query: String) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return nil }

        let encodedQuery = webSearchQueryEncoded(trimmedQuery)
        var expanded = template.replacingOccurrences(of: "%s", with: encodedQuery)
        expanded = replacingBraceTokens(in: expanded, encodedQuery: encodedQuery)

        guard templateProducedUsableURL(expanded) else { return nil }
        return expanded
    }

    /// True when `template` has somewhere to put the query. A template without
    /// a placeholder would silently open the same page for every input.
    static func containsQueryPlaceholder(_ template: String) -> Bool {
        if template.contains("%s") { return true }
        return queryTokens.contains { template.contains("{\($0)}") }
    }

    /// Walks `{...}` tokens once, substituting the query, known literals, and
    /// dropping everything else (optional `{foo?}` params and vendor tokens we
    /// have no value for — Chromium drops these too when it can't resolve them).
    private static func replacingBraceTokens(in template: String, encodedQuery: String) -> String {
        var output = ""
        output.reserveCapacity(template.count)

        var remainder = Substring(template)
        while let openIndex = remainder.firstIndex(of: "{") {
            output += remainder[remainder.startIndex..<openIndex]
            let afterOpen = remainder.index(after: openIndex)
            guard let closeIndex = remainder[afterOpen...].firstIndex(of: "}") else {
                // Unbalanced brace — keep the rest verbatim rather than looping.
                output += remainder[openIndex...]
                return output
            }
            let rawToken = String(remainder[afterOpen..<closeIndex])
            output += substitution(forToken: rawToken, encodedQuery: encodedQuery)
            remainder = remainder[remainder.index(after: closeIndex)...]
        }
        output += remainder
        return output
    }

    private static func substitution(forToken rawToken: String, encodedQuery: String) -> String {
        // A trailing `?` marks the parameter optional in Chromium's grammar.
        let token = rawToken.hasSuffix("?") ? String(rawToken.dropLast()) : rawToken
        if queryTokens.contains(token) { return encodedQuery }
        return literalSubstitutions[token] ?? ""
    }

    /// Rejects anything we can't hand to a browser as a normal web address —
    /// notably `edge://favorites/?q=` and friends, which are browser-internal
    /// pages that mean nothing when opened from outside the browser's own
    /// address bar (and which FastTab already covers natively anyway).
    private static func templateProducedUsableURL(_ expanded: String) -> Bool {
        guard let url = URL(string: expanded),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else { return false }
        return true
    }
}

// MARK: - Trigger parsing

/// Which keypress commits a typed keyword into alias mode. Tab is the browser
/// convention; space is the convenience most people reach for first.
enum SearchAliasTriggerKey: String, CaseIterable, Codable, Sendable {
    case tab
    case space

    var label: String {
        switch self {
        case .tab: return "Tab"
        case .space: return "Space"
        }
    }
}

enum SearchAliasMatching {
    /// Returns the alias whose keyword `text` exactly names, ignoring case and
    /// surrounding whitespace. Exact-only by design: a prefix match would make
    /// Space swallow the first word of ordinary searches.
    static func alias(committedBy text: String, in aliases: [SearchAlias]) -> SearchAlias? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return nil }
        return aliases.first { $0.keyword == candidate }
    }

    /// Ranks aliases for display: browser usage count first (the browser has
    /// been counting real hits for us), then keyword alphabetically so the
    /// long tail of never-used auto-discovered engines stays stable.
    static func ranked(_ aliases: [SearchAlias]) -> [SearchAlias] {
        aliases.sorted { lhs, rhs in
            if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
            return lhs.keyword.localizedCompare(rhs.keyword) == .orderedAscending
        }
    }

    /// One entry per distinct keyword, for display.
    ///
    /// The same engine is usually registered in several browser profiles
    /// (`baidu.com` in four, `@copilot` in three). Listing every copy makes the
    /// catalog look bigger than it is and implies choices the user doesn't
    /// have: only one row per keyword is reachable, because typing a keyword
    /// matches exactly one alias. Shows the winning row — same one the command
    /// bar picks — and how many other profiles also carry it.
    static func groupedByKeyword(_ aliases: [SearchAlias]) -> [(alias: SearchAlias, otherProfileCount: Int)] {
        var winners: [String: SearchAlias] = [:]
        var counts: [String: Int] = [:]
        for alias in ranked(aliases) {
            counts[alias.keyword, default: 0] += 1
            if winners[alias.keyword] == nil {
                winners[alias.keyword] = alias
            }
        }
        return ranked(Array(winners.values)).map { alias in
            (alias: alias, otherProfileCount: (counts[alias.keyword] ?? 1) - 1)
        }
    }

    /// Merges user-defined aliases over browser-imported ones.
    ///
    /// A user alias wins outright on keyword collision — it is the one the
    /// person deliberately created, and silently preferring an auto-discovered
    /// engine over it would be unexplainable. Among browser aliases sharing a
    /// keyword across profiles, the most-used one wins.
    static func merged(userAliases: [SearchAlias], browserAliases: [SearchAlias]) -> [SearchAlias] {
        var byKeyword: [String: SearchAlias] = [:]
        for alias in ranked(browserAliases) where byKeyword[alias.keyword] == nil {
            byKeyword[alias.keyword] = alias
        }
        for alias in userAliases {
            byKeyword[alias.keyword] = alias
        }
        return ranked(Array(byKeyword.values))
    }
}
