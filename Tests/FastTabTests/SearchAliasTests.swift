import Foundation
import Testing
@testable import FastTab

private func browserAlias(
    keyword: String,
    displayName: String = "Example",
    urlTemplate: String = "https://example.com/search?q={searchTerms}",
    profileName: String = "Default",
    appName: String = "Microsoft Edge",
    usageCount: Int = 0
) -> SearchAlias {
    SearchAlias(
        keyword: keyword,
        displayName: displayName,
        urlTemplate: urlTemplate,
        origin: .browser(appName: appName, profileName: profileName),
        usageCount: usageCount
    )
}

private func userAlias(
    keyword: String,
    displayName: String = "Mine",
    urlTemplate: String = "https://mine.example/?q=%s"
) -> SearchAlias {
    SearchAlias(keyword: keyword, displayName: displayName, urlTemplate: urlTemplate, origin: .user)
}

// MARK: - Template expansion

@Test func expandsChromiumSearchTermsToken() {
    let expanded = SearchAliasTemplate.expand(
        "https://github.com/search?q={searchTerms}&ref=opensearch",
        query: "rate limiter"
    )
    #expect(expanded == "https://github.com/search?q=rate%20limiter&ref=opensearch")
}

@Test func expandsPercentSTokenUsersTypeInSettings() {
    let expanded = SearchAliasTemplate.expand("https://mine.example/?q=%s", query: "hello world")
    #expect(expanded == "https://mine.example/?q=hello%20world")
}

/// Chromium marks optional parameters with a trailing `?`. Left in place they
/// would reach the site as a literal `{startPage?}`.
@Test func dropsOptionalTemplateParameters() {
    let expanded = SearchAliasTemplate.expand(
        "https://www.youtube.com/results?search_query={searchTerms}&page={startPage?}&utm_source=opensearch",
        query: "swift"
    )
    #expect(expanded == "https://www.youtube.com/results?search_query=swift&page=&utm_source=opensearch")
}

@Test func substitutesKnownVendorTokens() {
    let expanded = SearchAliasTemplate.expand(
        "{google:baseURL}search?q={searchTerms}&ie={inputEncoding}",
        query: "tabs"
    )
    #expect(expanded == "https://www.google.com/search?q=tabs&ie=UTF-8")
}

/// Browser-internal engines (`@favorites`, `@history`, `@tabs`) are real rows in
/// the keywords table but mean nothing outside the address bar — and FastTab
/// already searches bookmarks/history/tabs natively.
@Test func rejectsBrowserInternalTargets() {
    #expect(SearchAliasTemplate.expand("edge://favorites/?q={searchTerms}", query: "x") == nil)
    #expect(SearchAliasTemplate.expand("chrome://history/?q={searchTerms}", query: "x") == nil)
}

@Test func rejectsTemplateWithoutQueryPlaceholder() {
    #expect(SearchAliasTemplate.containsQueryPlaceholder("https://example.com/home") == false)
    #expect(SearchAliasTemplate.containsQueryPlaceholder("https://example.com/?q=%s"))
    #expect(SearchAliasTemplate.containsQueryPlaceholder("https://example.com/?q={searchTerms}"))
}

/// The load-bearing case for the whole feature: Jira's QuickSearch endpoint
/// resolves an exact issue key to that issue, so one alias covers both
/// "jump to ticket" and "search this Jira".
@Test func buildsJiraQuickSearchURLForATicketKey() {
    let alias = browserAlias(
        keyword: "sevensystemvn.atlassian.net",
        displayName: "7-Eleven Service Desk",
        urlTemplate: "https://sevensystemvn.atlassian.net/secure/QuickSearch.jspa?searchString={searchTerms}"
    )
    #expect(alias.expandedURL(query: "MM-690")
        == "https://sevensystemvn.atlassian.net/secure/QuickSearch.jspa?searchString=MM-690")
}

@Test func unbalancedBraceDoesNotHangOrCorruptRemainder() {
    let expanded = SearchAliasTemplate.expand("https://example.com/?q={searchTerms}&broken={oops", query: "a")
    #expect(expanded == "https://example.com/?q=a&broken={oops")
}

// MARK: - Trigger matching

@Test func commitsOnlyOnExactKeywordMatch() {
    let aliases = [browserAlias(keyword: "github.com"), userAlias(keyword: "jira")]

    #expect(SearchAliasMatching.alias(committedBy: "jira", in: aliases)?.keyword == "jira")
    #expect(SearchAliasMatching.alias(committedBy: "  JIRA  ", in: aliases)?.keyword == "jira")
    // A prefix must not commit, or Space would swallow the first word of any
    // ordinary search that happens to start with a keyword's prefix.
    #expect(SearchAliasMatching.alias(committedBy: "jir", in: aliases) == nil)
    #expect(SearchAliasMatching.alias(committedBy: "jira ticket", in: aliases) == nil)
    #expect(SearchAliasMatching.alias(committedBy: "", in: aliases) == nil)
}

// MARK: - Ranking and merging

@Test func ranksByBrowserUsageThenKeyword() {
    let ranked = SearchAliasMatching.ranked([
        browserAlias(keyword: "zebra.com", usageCount: 0),
        browserAlias(keyword: "youtube.com", usageCount: 64),
        browserAlias(keyword: "alpha.com", usageCount: 0),
        browserAlias(keyword: "drive.google.com", usageCount: 25)
    ])
    #expect(ranked.map(\.keyword) == ["youtube.com", "drive.google.com", "alpha.com", "zebra.com"])
}

@Test func userAliasWinsOverImportedOneWithSameKeyword() {
    let merged = SearchAliasMatching.merged(
        userAliases: [userAlias(keyword: "gh", displayName: "My GitHub")],
        browserAliases: [browserAlias(keyword: "gh", displayName: "GitHub", usageCount: 99)]
    )
    #expect(merged.count == 1)
    #expect(merged.first?.displayName == "My GitHub")
    #expect(merged.first?.origin == .user)
}

/// The same keyword often exists in several profiles. The most-used copy is the
/// one whose session the user actually has.
@Test func mostUsedProfileWinsForDuplicateBrowserKeyword() {
    let merged = SearchAliasMatching.merged(
        userAliases: [],
        browserAliases: [
            browserAlias(keyword: "github.com", profileName: "Profile 3", usageCount: 2),
            browserAlias(keyword: "github.com", profileName: "Profile 1", usageCount: 40)
        ]
    )
    #expect(merged.count == 1)
    #expect(merged.first?.origin.profileName == "Profile 1")
}

/// The same engine is registered in several profiles; the Settings list must
/// show one reachable row per keyword, not one row per profile copy.
@Test func groupsDuplicateKeywordsForDisplay() {
    let grouped = SearchAliasMatching.groupedByKeyword([
        browserAlias(keyword: "baidu.com", profileName: "Profile 1", usageCount: 0),
        browserAlias(keyword: "baidu.com", profileName: "Profile 3", usageCount: 4),
        browserAlias(keyword: "baidu.com", profileName: "Guest Profile", usageCount: 1),
        browserAlias(keyword: "claude", profileName: "Profile 1", usageCount: 12)
    ])

    #expect(grouped.map(\.alias.keyword) == ["claude", "baidu.com"])

    let baidu = try! #require(grouped.first { $0.alias.keyword == "baidu.com" })
    // Winner is the most-used copy — the same one the command bar would open.
    #expect(baidu.alias.origin.profileName == "Profile 3")
    #expect(baidu.otherProfileCount == 2)

    let claude = try! #require(grouped.first { $0.alias.keyword == "claude" })
    #expect(claude.otherProfileCount == 0)
}

// MARK: - keywords-table parsing

private func keywordsRow(_ fields: String...) -> String {
    fields.joined(separator: kFieldSep)
}

@Test func parsesKeywordsTableRows() {
    let output = [
        keywordsRow("claude", "Claude chat history search", "https://claude.ai/recents?search={searchTerms}", "12"),
        keywordsRow("youtube.com", "YouTube", "https://www.youtube.com/results?search_query={searchTerms}", "64")
    ].joined(separator: "\n")

    let aliases = ChromiumSearchEngineReader.parseAliases(
        sqliteOutput: output,
        browserAppName: "Microsoft Edge",
        profileName: "Profile 1"
    )

    #expect(aliases.count == 2)
    #expect(aliases.first?.keyword == "claude")
    #expect(aliases.first?.usageCount == 12)
    #expect(aliases.first?.origin == .browser(appName: "Microsoft Edge", profileName: "Profile 1"))
}

@Test func skipsRowsThatCouldNeverOpen() {
    let output = [
        // No placeholder — would open the same page for every query.
        keywordsRow("static.com", "Static", "https://static.example/home", "3"),
        // Browser-internal.
        keywordsRow("@favorites", "Favorites", "edge://favorites/?q={searchTerms}", "0"),
        // Truncated row.
        keywordsRow("broken.com", "Broken"),
        keywordsRow("ok.com", "OK", "https://ok.example/?q={searchTerms}", "1")
    ].joined(separator: "\n")

    let aliases = ChromiumSearchEngineReader.parseAliases(
        sqliteOutput: output,
        browserAppName: "Google Chrome",
        profileName: "Default"
    )

    #expect(aliases.map(\.keyword) == ["ok.com"])
}

/// Auto-discovered rows frequently carry a blank or wrong `short_name`; an
/// empty label would render as a nameless row.
@Test func fallsBackToKeywordWhenShortNameIsBlank() {
    let output = keywordsRow("libgen.im", "  ", "https://libgen.im/?q={searchTerms}", "0")
    let aliases = ChromiumSearchEngineReader.parseAliases(
        sqliteOutput: output,
        browserAppName: "Microsoft Edge",
        profileName: "Profile 1"
    )
    #expect(aliases.first?.displayName == "libgen.im")
}

// MARK: - Store

@MainActor
@Test func storePersistsAndMergesUserAliases() {
    let defaults = UserDefaults(suiteName: "FastTabTests.searchAlias.\(UUID().uuidString)")!
    let store = SearchAliasStore(defaults: defaults)

    #expect(store.upsertUserAlias(keyword: "JIRA", displayName: "Work Jira", urlTemplate: "https://msv-tech.atlassian.net/browse/%s"))
    #expect(store.userAliases.first?.keyword == "jira")

    // Re-reading the same defaults must restore it.
    let reloaded = SearchAliasStore(defaults: defaults)
    #expect(reloaded.userAliases.first?.displayName == "Work Jira")

    store.removeUserAlias(keyword: "jira")
    #expect(store.userAliases.isEmpty)
}

@MainActor
@Test func storeRejectsAliasWithNoPlaceholderOrBadScheme() {
    let defaults = UserDefaults(suiteName: "FastTabTests.searchAlias.\(UUID().uuidString)")!
    let store = SearchAliasStore(defaults: defaults)

    #expect(store.upsertUserAlias(keyword: "x", displayName: "", urlTemplate: "https://example.com/home") == false)
    #expect(store.upsertUserAlias(keyword: "y", displayName: "", urlTemplate: "notaurl/%s") == false)
    #expect(store.userAliases.isEmpty)
}

@MainActor
@Test func triggerKeysDefaultToBothAndPersistAnEmptySelection() {
    let defaults = UserDefaults(suiteName: "FastTabTests.searchAlias.\(UUID().uuidString)")!
    let store = SearchAliasStore(defaults: defaults)
    #expect(store.triggerKeys == Set(SearchAliasTriggerKey.allCases))

    store.setTrigger(.space, enabled: false)
    store.setTrigger(.tab, enabled: false)

    // An explicit "both off" must survive a reload rather than resetting to
    // the default — otherwise the setting appears not to stick.
    let reloaded = SearchAliasStore(defaults: defaults)
    #expect(reloaded.triggerKeys.isEmpty)
}
