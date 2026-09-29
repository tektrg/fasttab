import Foundation

struct AuthoritativeLiveTabSnapshot {
    private(set) var tabs: [BrowserSearchResult] = []
    private(set) var isHydrated = false
    /// When `tabs` was last refreshed from the backends. Lets the state-zone
    /// reconciliation refuse to delete records based on a stale or partially
    /// fetched view of what is open — a tab that momentarily dropped out of a
    /// broken fetch must not be treated as closed.
    private(set) var lastFetchedAt: Date?
    /// Browsers whose read failed in this refresh. Their entries in `tabs`
    /// (if any) are carried forward from the previous refresh, so the
    /// reconciliation must not delete their records against it.
    private(set) var unreadableBrowsers: Set<String> = []

    mutating func applyAllBackends(_ tabs: [BrowserSearchResult], unreadableBrowsers: Set<String> = []) {
        self.tabs = tabs
        self.unreadableBrowsers = unreadableBrowsers
        isHydrated = true
        lastFetchedAt = Date()
    }

    mutating func observeScopedFetch(_ tabs: [BrowserSearchResult]) {
        _ = tabs
        // Scoped results are UI-only and must never replace global sync state.
    }
}
