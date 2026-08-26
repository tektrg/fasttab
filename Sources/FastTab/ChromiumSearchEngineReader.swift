import Foundation
import OSLog

/// Imports a Chromium profile's address-bar search engines as `SearchAlias`es.
///
/// Why import instead of asking the user to configure aliases: Chromium already
/// auto-discovers search engines from every site that publishes an OpenSearch
/// descriptor, and has been counting how often each one is used. That table is
/// a better-maintained version of the same data FastTab would otherwise try to
/// infer, and it syncs across the user's machines through their browser
/// profile. We read it; we never write to it.
enum ChromiumSearchEngineReader {
    /// `keywords` rows we skip outright, before template validation:
    /// - `keyword`/`url` empty — unusable.
    /// - Browser-internal targets (`edge://history/all?q=`) — these are the
    ///   browser's own bookmark/history/tab search, which FastTab already does
    ///   natively and which mean nothing opened from outside the address bar.
    ///   `SearchAliasTemplate` rejects them too; excluding them in SQL just
    ///   keeps the parsed set small.
    private static let selectUsableKeywordsSQL = """
    SELECT keyword, short_name, url, usage_count
    FROM keywords
    WHERE keyword IS NOT NULL AND keyword != ''
      AND url IS NOT NULL AND url != ''
      AND url NOT LIKE 'chrome://%'
      AND url NOT LIKE 'edge://%'
      AND url NOT LIKE 'brave://%'
      AND coalesce(search_url_post_params, '') = '';
    """

    /// Reads every usable alias across `profiles`. Profiles without a
    /// `Web Data` file (or whose read fails) contribute nothing rather than
    /// failing the whole import — one locked profile must not cost the user
    /// the aliases from their other profiles.
    static func importAliases(from profiles: [ChromiumProfile], logger: Logger) -> [SearchAlias] {
        profiles.flatMap { importAliases(from: $0, logger: logger) }
    }

    static func importAliases(from profile: ChromiumProfile, logger: Logger) -> [SearchAlias] {
        let dbPath = profile.webDataURL.path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        guard let output = runProcess(
            launchPath: "/usr/bin/sqlite3",
            arguments: immutableReadSQLiteArgs(dbPath: dbPath, sql: selectUsableKeywordsSQL),
            timeoutSeconds: 5
        ) else {
            logger.error("search-engine import failed. app='\(profile.browserAppName, privacy: .public)' profile='\(profile.name, privacy: .public)'")
            return []
        }

        let aliases = parseAliases(
            sqliteOutput: output,
            browserAppName: profile.browserAppName,
            profileName: profile.name
        )
        logger.info("search-engine import complete. app='\(profile.browserAppName, privacy: .public)' profile='\(profile.name, privacy: .public)' aliases=\(aliases.count)")
        return aliases
    }

    /// Split out from the I/O so template handling is unit-testable without a
    /// real browser profile on disk.
    static func parseAliases(
        sqliteOutput: String,
        browserAppName: String,
        profileName: String
    ) -> [SearchAlias] {
        var aliases: [SearchAlias] = []

        for row in sqliteOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = String(row).components(separatedBy: kFieldSep)
            guard fields.count >= 4 else { continue }

            let keyword = fields[0]
            let urlTemplate = fields[2]
            guard SearchAliasTemplate.containsQueryPlaceholder(urlTemplate) else { continue }

            // `short_name` is frequently wrong or duplicated in auto-discovered
            // rows (three unrelated sites all naming themselves "GitHub"), so
            // fall back to the keyword rather than showing an empty label.
            let shortName = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let alias = SearchAlias(
                keyword: keyword,
                displayName: shortName.isEmpty ? keyword : shortName,
                urlTemplate: urlTemplate,
                origin: .browser(appName: browserAppName, profileName: profileName),
                usageCount: Int(fields[3]) ?? 0
            )
            guard alias.isOpenable else { continue }
            aliases.append(alias)
        }

        return aliases
    }
}
