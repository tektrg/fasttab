import Foundation

struct AuthoritativeLiveTabSnapshot {
    private(set) var tabs: [BrowserSearchResult] = []
    private(set) var isHydrated = false

    mutating func applyAllBackends(_ tabs: [BrowserSearchResult]) {
        self.tabs = tabs
        isHydrated = true
    }

    mutating func observeScopedFetch(_ tabs: [BrowserSearchResult]) {
        _ = tabs
        // Scoped results are UI-only and must never replace global sync state.
    }
}
