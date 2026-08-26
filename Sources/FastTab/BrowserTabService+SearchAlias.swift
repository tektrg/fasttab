import Foundation
import OSLog

/// Search-alias side of `BrowserTabService`: importing the browsers' own
/// address-bar search engines, and opening an expanded alias URL.
///
/// Kept out of `BrowserTabService.swift` because that file is already well past
/// the size where adding unrelated concerns hurts navigability.
extension BrowserTabService {
    private var searchAliasLogger: Logger {
        Logger(subsystem: "com.trungluong.FastTab", category: "SearchAlias")
    }

    /// Re-imports every Chromium profile's search engines into
    /// `SearchAliasStore`.
    ///
    /// Runs as its own detached task rather than inside the bookmarks/history
    /// cache refresh so a slow or locked `Web Data` read can never delay the
    /// results the user is actually waiting on.
    func refreshSearchAliases() {
        // Cast to the protocol, not to `ChromiumBackend`: every Chromium backend
        // is wrapped in `ExtensionBackedBackend`, so a concrete-type cast
        // matches nothing and the import silently does no work.
        let profileProviders = backends.compactMap { $0 as? any ChromiumProfileAccess }
        guard !profileProviders.isEmpty else { return }

        let logger = searchAliasLogger
        Task.detached(priority: .utility) {
            let imported = profileProviders.flatMap { provider in
                ChromiumSearchEngineReader.importAliases(from: provider.chromiumProfiles(), logger: logger)
            }
            await MainActor.run {
                SearchAliasStore.shared.replaceImportedAliases(imported)
            }
        }
    }

    /// Opens `alias` filled in with `query`.
    ///
    /// Targets the browser profile the alias was imported from whenever that
    /// browser is still available: the user's logged-in session for that site
    /// lives in that specific profile, so opening a Jira link in the wrong
    /// profile lands on a login wall instead of the ticket. User-defined
    /// aliases have no owning profile and fall back to the same browser a plain
    /// web search would use.
    func openSearchAlias(_ alias: SearchAlias, query: String) {
        guard let expandedURL = alias.expandedURL(query: query) else {
            searchAliasLogger.error("openSearchAlias: template did not expand. keyword='\(alias.keyword, privacy: .public)'")
            return
        }

        let owningBackend = alias.origin.browserAppName.flatMap { appName in
            backends.first { $0.appName == appName }
        }
        guard let targetBackend = owningBackend ?? resolvedWebSearchBackend() else { return }

        // Only carry the profile through when we actually reached the browser
        // it belongs to — a profile name from a different browser is meaningless.
        let targetProfileName = owningBackend == nil ? nil : alias.origin.profileName

        let result = BrowserSearchResult(
            title: alias.displayName,
            url: expandedURL,
            browserName: targetBackend.appName,
            type: .history,
            timestamp: Date(),
            profileName: targetProfileName
        )

        searchAliasLogger.info("openSearchAlias: keyword='\(alias.keyword, privacy: .public)' browser='\(targetBackend.appName, privacy: .public)' profile='\(targetProfileName ?? "-", privacy: .public)'")
        Task.detached(priority: .userInitiated) {
            targetBackend.openURL(result)
        }
    }
}
