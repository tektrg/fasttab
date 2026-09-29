import Foundation

/// Result of reading one browser's open tabs.
///
/// `unreadable` is NOT "zero tabs": the read timed out, the AppleScript
/// errored, or osascript failed. Publishing it as an empty list would make the
/// Mac delete every one of that browser's tabs from the phone. A browser that
/// is genuinely not running (or has no windows) is `.fetched([])`.
enum LiveTabFetchOutcome: Equatable, Sendable {
    case fetched([BrowserSearchResult])
    case unreadable

    var tabs: [BrowserSearchResult] {
        if case .fetched(let tabs) = self { return tabs }
        return []
    }
}

/// Returned by the live-tab AppleScripts from their `on error` branch, so a
/// failed read is distinguishable from a browser with no tabs (empty output).
let kLiveTabReadFailedSentinel = "__FASTTAB_LIVE_TAB_READ_FAILED__"

/// What a live-tab AppleScript's raw output means.
enum LiveTabScriptOutput: Equatable {
    /// osascript timed out / failed (`nil`), or the script hit its error branch.
    case unreadable
    /// Browser not running, or running with no windows.
    case noTabs
    case rows(String)

    init(rawOutput: String?) {
        guard let rawOutput else { self = .unreadable; return }
        if rawOutput == kLiveTabReadFailedSentinel {
            self = .unreadable
        } else if rawOutput.isEmpty {
            self = .noTabs
        } else {
            self = .rows(rawOutput)
        }
    }
}

/// Timing and trust decisions for keeping the phone's tab list current while
/// FastTab sits idle. Pure so they are unit-testable (tests cannot touch
/// `BrowserTabService.shared` or CloudKit).
enum LiveTabRefreshPolicy {
    /// Idle upload cadence for browsers without the extension (AppleScript
    /// path). Each run is one AppleScript read per browser (~100–600 ms, off
    /// the main thread); the publish fingerprint skips CloudKit when nothing
    /// changed.
    nonisolated static let idleRefreshInterval: TimeInterval = 60
    /// Extension tab events (close/open/navigate) upload at most this often.
    nonisolated static let extensionEventMinimumInterval: TimeInterval = 5
    /// Short trailing wait so a burst (closing a window = one event per tab)
    /// becomes a single refresh.
    nonisolated static let extensionEventCoalesceDelay: TimeInterval = 1

    /// Seconds to wait before the refresh triggered by an extension tab event:
    /// at least the coalesce delay, and never sooner than the minimum interval
    /// after the previous authoritative refresh started.
    nonisolated static func extensionEventRefreshDelay(lastRefreshStartedAt: Date?, now: Date) -> TimeInterval {
        let coalesce = extensionEventCoalesceDelay
        guard let lastRefreshStartedAt else { return coalesce }
        let throttleRemaining = lastRefreshStartedAt.addingTimeInterval(extensionEventMinimumInterval).timeIntervalSince(now)
        return max(coalesce, throttleRemaining)
    }

    /// Whether the idle poll should run an authoritative refresh now. Any
    /// refresh (bar open, phone close, extension event) resets the clock.
    nonisolated static func shouldRunIdleRefresh(lastRefreshStartedAt: Date?, now: Date) -> Bool {
        guard let lastRefreshStartedAt else { return true }
        return now.timeIntervalSince(lastRefreshStartedAt) >= idleRefreshInterval
    }

    /// Replaces each unreadable browser's (empty) result with its tabs from
    /// the previous snapshot, so a timed-out read keeps that browser's tabs
    /// instead of deleting them. With an empty previous snapshot (first read
    /// after launch) there is nothing to carry forward and the browser is left
    /// empty — the legacy behaviour; the next readable refresh repairs it.
    nonisolated static func carryingForwardUnreadableBrowsers(
        fetched: [BrowserSearchResult],
        unreadableBrowsers: Set<String>,
        previous: [BrowserSearchResult]
    ) -> [BrowserSearchResult] {
        guard !unreadableBrowsers.isEmpty else { return fetched }
        let readable = fetched.filter { !unreadableBrowsers.contains($0.browserName) }
        let carried = previous.filter { unreadableBrowsers.contains($0.browserName) }
        return readable + carried
    }

    /// Whether an authoritative snapshot may drive reconciliation deletes.
    nonisolated static func isSnapshotFreshForReconcile(
        isHydrated: Bool,
        lastFetchedAt: Date?,
        now: Date,
        maxAge: TimeInterval
    ) -> Bool {
        guard isHydrated, let lastFetchedAt else { return false }
        return now.timeIntervalSince(lastFetchedAt) < maxAge
    }
}
