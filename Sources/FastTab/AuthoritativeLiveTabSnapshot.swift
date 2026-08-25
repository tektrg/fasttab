import Foundation

struct AuthoritativeLiveTabSnapshot {
    private(set) var tabs: [BrowserSearchResult] = []
    private(set) var isHydrated = false
    /// When `tabs` was last refreshed from the backends. Lets the state-zone
    /// reconciliation refuse to delete records based on a stale or partially
    /// fetched view of what is open — a tab that momentarily dropped out of a
    /// broken fetch must not be treated as closed.
    private(set) var lastFetchedAt: Date?

    mutating func applyAllBackends(_ tabs: [BrowserSearchResult]) {
        self.tabs = tabs
        isHydrated = true
        lastFetchedAt = Date()
    }

    mutating func observeScopedFetch(_ tabs: [BrowserSearchResult]) {
        _ = tabs
        // Scoped results are UI-only and must never replace global sync state.
    }
}
