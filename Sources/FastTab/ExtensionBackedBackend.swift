import Foundation
import OSLog

private let extensionBackedBackendLogger = Logger(subsystem: "com.trungluong.FastTab", category: "ExtensionBackedBackend")

/// Access to a Chromium browser's on-disk profiles.
///
/// `profileCount()` gates the decorator: it serves the extension snapshot only
/// when every profile is connected, so a partial profile set can never hide
/// tabs. `chromiumProfiles()` exposes the profiles themselves for the readers
/// that work off profile files directly (search-engine import).
///
/// Extracted as a protocol so tests can mock the inner backend — and so callers
/// go through the decorator instead of casting to `ChromiumBackend`, which
/// silently matches nothing now that every Chromium backend is wrapped.
protocol ChromiumProfileAccess: Sendable {
    func profileCount() -> Int
    func chromiumProfiles() -> [ChromiumProfile]
}

extension ChromiumBackend: ChromiumProfileAccess {
    func chromiumProfiles() -> [ChromiumProfile] { profiles() }

    /// Prefers the count of profiles the browser currently has open
    /// (`livingProfileNames`) over every profile folder ever created on
    /// disk — the latter overcounts so badly (abandoned Guest Profile,
    /// years-old dead profiles) that the completeness gate below would
    /// never pass. Falls back to the disk count only when live detection
    /// is unavailable, never under-counting.
    func profileCount() -> Int {
        if let living = livingProfileNames(), !living.isEmpty {
            return living.count
        }
        return profiles().count
    }
}

/// Enrichment decorator over a Chromium-family backend.
///
/// v1 serves *tabs only* from the companion extension: live-tab fetch, the
/// active-tab poll, and tab activate/close (by stable tab ID) — all read
/// synchronously from the in-memory bridge snapshot, so they're instant and
/// carry exact activation times and real tab state. Every other method, and
/// every call when the beta gate is off or the bridge isn't servable, falls
/// through to the wrapped backend unchanged. The extension can never make
/// FastTab slower or less complete than today.
struct ExtensionBackedBackend<Inner: BrowserBackend & ChromiumProfileAccess>: BrowserBackend, ChromiumProfileAccess {
    let inner: Inner
    let bridge: any ExtensionBridgeServing

    var appName: String { inner.appName }
    var bundleIdentifier: String { inner.bundleIdentifier }

    // Profile access is pure disk state the extension has no view of, so the
    // decorator always forwards it. Conforming (rather than leaving callers to
    // cast at the concrete inner type) is what keeps profile-backed features
    // working once a backend is wrapped.
    func profileCount() -> Int { inner.profileCount() }
    func chromiumProfiles() -> [ChromiumProfile] { inner.chromiumProfiles() }

    private var isBetaEnabled: Bool { ExtensionBetaPreference.isEnabled }

    /// The extension snapshot, only when the beta is on and the bridge reports
    /// a complete, fresh connection for this browser. Nil → fall through to
    /// the inner backend (the plan's "speed always wins" rule: never wait).
    /// Logs the outcome — this is the one place that answers "why did this
    /// fetch use the extension vs. AppleScript" (check Console.app or
    /// `/usr/bin/log show --predicate 'category == "ExtensionBackedBackend"'`;
    /// note the plain `log` command is shadowed by a shell builtin in some
    /// shells — use the full `/usr/bin/log` path).
    private func servableView() -> ExtensionSnapshotView? {
        guard isBetaEnabled else { return nil }
        let view = bridge.snapshotView(for: appName, profileCount: inner.profileCount())
        extensionBackedBackendLogger.info("servableView. app=\(self.appName, privacy: .public) servable=\(view != nil, privacy: .public) tabCount=\(view?.tabs.count ?? -1, privacy: .public)")
        return view
    }

    // MARK: - Live tabs (extension snapshot when servable)

    func fetchLiveTabs(
        fetchStart: Date,
        activeTimes: inout [String: Date],
        currentFlowSourceAppBundleIdentifier: String?
    ) -> [BrowserSearchResult] {
        guard let view = servableView() else {
            return inner.fetchLiveTabs(
                fetchStart: fetchStart,
                activeTimes: &activeTimes,
                currentFlowSourceAppBundleIdentifier: currentFlowSourceAppBundleIdentifier
            )
        }

        let isSourceFrontmost = bundleIdentifier == currentFlowSourceAppBundleIdentifier
        var results: [BrowserSearchResult] = []
        results.reserveCapacity(view.tabs.count)

        for tab in view.tabs {
            // Only the active tab of the front window of the source browser is
            // "the tab the user is on" — mirrors the AppleScript path's rule.
            let isFrontActive = tab.isActive && tab.windowIndex == 1 && isSourceFrontmost
            let key = makeTabRecencyKey(browserName: appName, windowIndex: tab.windowIndex, tabIndex: tab.tabIndex, url: tab.url)
            let urlKey = makeTabURLRecencyKey(browserName: appName, url: tab.url)
            let storedTime = activeTimes[key] ?? activeTimes[urlKey]
            let timestamp: Date
            if isFrontActive {
                timestamp = fetchStart
            } else if let activation = view.activationTimes[tab.tabID] {
                if let stored = storedTime {
                    timestamp = max(activation, stored)
                } else {
                    timestamp = activation
                }
            } else if let lastAccessed = tab.lastAccessed {
                if let stored = storedTime {
                    timestamp = max(lastAccessed, stored)
                } else {
                    timestamp = lastAccessed
                }
            } else {
                timestamp = storedTime ?? Date(timeIntervalSince1970: 0)
            }

            // Exact activation times flow into the app's recency store so
            // quick-open and frecency ranking use truth, not a poll guess.
            if timestamp > Date(timeIntervalSince1970: 0) {
                activeTimes[key] = timestamp
                activeTimes[urlKey] = timestamp
            }

            let isAudibleToUser = tab.isAudible && !tab.isMuted

            results.append(BrowserSearchResult(
                title: tab.title,
                url: tab.url,
                browserName: appName,
                type: .tab,
                timestamp: timestamp,
                windowIndex: tab.windowIndex,
                tabIndex: tab.tabIndex,
                windowName: tab.windowName,
                isCurrentFlowActiveTab: isFrontActive,
                hasMediaIndicator: isAudibleToUser,
                tabID: tab.tabID,
                isAudible: tab.isAudible,
                isMuted: tab.isMuted,
                isPinned: tab.isPinned,
                isDiscarded: tab.isDiscarded,
                tabGroupTitle: tab.groupTitle,
                isPinnedAudibleTab: isAudibleToUser
            ))
        }

        let audibleTabs = view.tabs.filter(\.isAudible)
        if !audibleTabs.isEmpty {
            let preview = audibleTabs.map { "[win=\($0.windowIndex) tab=\($0.tabIndex) muted=\($0.isMuted) '\($0.title.prefix(40))']" }.joined(separator: " ")
            extensionBackedBackendLogger.info("audible tabs this fetch. app=\(self.appName, privacy: .public) count=\(audibleTabs.count) \(preview, privacy: .public)")
        }
        return results
    }

    func pollActiveTabKeys() -> [String] {
        guard let view = servableView() else { return inner.pollActiveTabKeys() }
        guard let front = view.tabs.first(where: { $0.windowIndex == 1 && $0.isActive }) else { return [] }
        return [
            makeTabRecencyKey(browserName: appName, windowIndex: front.windowIndex, tabIndex: front.tabIndex, url: front.url),
            makeTabURLRecencyKey(browserName: appName, url: front.url)
        ]
    }

    // MARK: - Tab actions (stable tab ID when present, AppleScript fallback)

    func activateTab(_ result: BrowserSearchResult) {
        if let tabID = result.tabID, isBetaEnabled,
           bridge.sendCommand(appName: appName, type: "activateTab", tabID: tabID, timeout: 1.5) {
            return
        }
        inner.activateTab(result)
    }

    func closeTab(_ result: BrowserSearchResult) {
        if let tabID = result.tabID, isBetaEnabled,
           bridge.sendCommand(appName: appName, type: "closeTab", tabID: tabID, timeout: 1.5) {
            return
        }
        inner.closeTab(result)
    }

    func closeTabWithResult(_ result: BrowserSearchResult, allowPositionalFallback: Bool) -> TabCloseResult {
        if let tabID = result.tabID, isBetaEnabled {
            if bridge.sendCommand(appName: appName, type: "closeTab", tabID: tabID, timeout: 1.5) {
                return .closed
            }
        }
        return inner.closeTabWithResult(result, allowPositionalFallback: allowPositionalFallback)
    }

    /// Mute/unmute has no AppleScript equivalent — Chrome doesn't expose a
    /// scriptable "muted" property — so this is extension-only with no
    /// fallback. Silently no-ops when the beta is off or the tab has no
    /// stable ID, same as the rest of this backend's speed-first contract.
    func toggleMuteTab(_ result: BrowserSearchResult, muted: Bool) {
        guard let tabID = result.tabID, isBetaEnabled else {
            extensionBackedBackendLogger.error("toggleMuteTab: no-op. app=\(self.appName, privacy: .public) hasTabID=\(result.tabID != nil) betaEnabled=\(self.isBetaEnabled)")
            return
        }
        let ok = bridge.sendCommand(appName: appName, type: "setMuted", tabID: tabID, extraPayload: ["muted": muted], timeout: 1.5)
        extensionBackedBackendLogger.info("toggleMuteTab sent. app=\(self.appName, privacy: .public) tabID=\(tabID) muted=\(muted) ok=\(ok)")
    }

    func togglePinTab(_ result: BrowserSearchResult, pinned: Bool) {
        guard let tabID = result.tabID, isBetaEnabled else {
            extensionBackedBackendLogger.error("togglePinTab: no-op. app=\(self.appName, privacy: .public) hasTabID=\(result.tabID != nil) betaEnabled=\(self.isBetaEnabled)")
            return
        }
        let ok = bridge.sendCommand(appName: appName, type: "setPinned", tabID: tabID, extraPayload: ["pinned": pinned], timeout: 1.5)
        extensionBackedBackendLogger.info("togglePinTab sent. app=\(self.appName, privacy: .public) tabID=\(tabID) pinned=\(pinned) ok=\(ok)")
    }

    // MARK: - Everything else delegates unconditionally in v1

    func fetchAllBookmarks() -> [BrowserSearchResult] { inner.fetchAllBookmarks() }
    func fetchBookmarkTree() -> [BookmarkFolder] { inner.fetchBookmarkTree() }
    func fetchRecentHistory(perBrowserLimit: Int) -> [BrowserSearchResult] { inner.fetchRecentHistory(perBrowserLimit: perBrowserLimit) }
    func searchHistory(query: String, limit: Int) -> [BrowserSearchResult] { inner.searchHistory(query: query, limit: limit) }
    func searchHistory(query: String, limit: Int, since: Date?, before: Date?) -> [BrowserSearchResult] {
        inner.searchHistory(query: query, limit: limit, since: since, before: before)
    }
    func searchHistory(query: String, limit: Int, since: Date?, before: Date?, timeoutSeconds: TimeInterval) -> [BrowserSearchResult] {
        inner.searchHistory(query: query, limit: limit, since: since, before: before, timeoutSeconds: timeoutSeconds)
    }
    func fetchFaviconData(pageURL: String) -> Data? { inner.fetchFaviconData(pageURL: pageURL) }
    func fetchFaviconsBatch(pageURLs: [String]) -> [String: Data] { inner.fetchFaviconsBatch(pageURLs: pageURLs) }
    func openURL(_ result: BrowserSearchResult) { inner.openURL(result) }
    func openInInstalledWebApp(_ result: BrowserSearchResult, app: InstalledWebApp) { inner.openInInstalledWebApp(result, app: app) }
    @discardableResult
    func deleteBookmark(_ result: BrowserSearchResult) -> Bool {
        if bridge.deleteBookmark(appName: appName, id: result.bookmarkID, url: result.url) {
            extensionBackedBackendLogger.info("deleteBookmark via extension succeeded for app=\(self.appName, privacy: .public)")
            _ = inner.deleteBookmark(result)
            return true
        }
        return inner.deleteBookmark(result)
    }
    func deleteHistoryItem(_ result: BrowserSearchResult) { inner.deleteHistoryItem(result) }
    func removeBookmarkForMove(_ result: BrowserSearchResult) -> RemovedBookmarkNode? {
        inner.removeBookmarkForMove(result)
    }
    func insertBookmark(title: String, url: String, dateAdded: Date?, profileName: String, folderPath: [String]) -> Bool {
        inner.insertBookmark(title: title, url: url, dateAdded: dateAdded, profileName: profileName, folderPath: folderPath)
    }
    func createBookmarkFolder(name: String, parentPath: [String], profileName: String) -> Bool {
        inner.createBookmarkFolder(name: name, parentPath: parentPath, profileName: profileName)
    }
    func moveBookmark(id: String, parentId: String?, index: Int?) -> Bool {
        ExtensionBridge.shared.moveBookmark(appName: appName, id: id, parentId: parentId, index: index)
    }
    func updateBookmark(id: String, title: String?, url: String?) -> Bool {
        ExtensionBridge.shared.updateBookmark(appName: appName, id: id, title: title, url: url)
    }
}
