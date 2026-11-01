import FastTabSync
import Foundation

/// The bridge a command-bar row offers between the FastTab List and browser Bookmarks.
enum FastTabListRowBridge: Equatable {
    /// Tab or bookmark → add to the FastTab List.
    case readLater
    /// FastTab List item → browser bookmark, then the item goes to Trash.
    case moveToBookmarks

    var title: String {
        switch self {
        case .readLater: return "Read later"
        case .moveToBookmarks: return "Move to Bookmarks"
        }
    }

    var symbolName: String {
        switch self {
        case .readLater: return "eyeglasses"
        case .moveToBookmarks: return "bookmark"
        }
    }

    /// Which bridge (if any) `result` offers: web tabs and bookmarks can be read later,
    /// list items can become bookmarks. Finder windows, ghosts and history rows offer none.
    static func forResult(_ result: BrowserSearchResult) -> FastTabListRowBridge? {
        switch result.type {
        case .fastTabList:
            return .moveToBookmarks
        case .tab where !result.isGhost, .bookmark:
            return FastTabListBridge.isReadableWebURL(result.url) ? .readLater : nil
        case .tab, .sent, .history:
            return nil
        }
    }
}

/// Where "Move to Bookmarks" writes on this Mac: the top level ("Other Bookmarks") of a
/// browser profile that already holds bookmarks FastTab can write to.
struct FastTabListBookmarkDestination: Equatable {
    let browserName: String
    let profileName: String

    /// Picks the profile with the most bookmarks, preferring `preferredBrowser` (the one
    /// the user is working in). Only browsers in `writableBrowsers` qualify.
    static func choose(
        preferredBrowser: String?,
        writableBrowsers: Set<String>,
        bookmarks: [BrowserSearchResult]
    ) -> FastTabListBookmarkDestination? {
        var counts: [FastTabListBookmarkDestinationKey: Int] = [:]
        for bookmark in bookmarks where bookmark.type == .bookmark && writableBrowsers.contains(bookmark.browserName) {
            guard let profile = bookmark.profileName, !profile.isEmpty else { continue }
            counts[FastTabListBookmarkDestinationKey(browserName: bookmark.browserName, profileName: profile), default: 0] += 1
        }
        let best = counts.max { lhs, rhs in
            let lhsPreferred = lhs.key.browserName == preferredBrowser
            let rhsPreferred = rhs.key.browserName == preferredBrowser
            if lhsPreferred != rhsPreferred { return rhsPreferred }
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            // Stable tie-break so the same library always picks the same profile.
            return (lhs.key.browserName, lhs.key.profileName) > (rhs.key.browserName, rhs.key.profileName)
        }
        return best.map { FastTabListBookmarkDestination(browserName: $0.key.browserName, profileName: $0.key.profileName) }
    }
}

private struct FastTabListBookmarkDestinationKey: Hashable {
    let browserName: String
    let profileName: String
}

extension BrowserTabService {
    /// Row label used as `browserName` for list items (keeps them out of browser dedupe).
    nonisolated static let fastTabListSourceName = "FastTab List"

    /// FastTab List items as command-bar rows. `folderPath` carries the row hint
    /// ("example.com • 40% read"), shown where a bookmark shows its folder.
    nonisolated static func fastTabListResults(from items: [SavedOnIPhoneLink]) -> [BrowserSearchResult] {
        items.filter { !$0.isTrashed }.map { item in
            let hint = [FastTabListBridge.domain(of: item.url), FastTabListBridge.progressHint(for: item)]
                .compactMap { $0 }
                .joined(separator: " • ")
            return BrowserSearchResult(
                title: item.title ?? FastTabListBridge.domain(of: item.url) ?? item.url,
                url: item.url,
                browserName: fastTabListSourceName,
                type: .fastTabList,
                timestamp: item.savedAt,
                bookmarkID: item.id,
                folderPath: hint.isEmpty ? nil : hint
            )
        }
    }

    func currentFastTabListResults() -> [BrowserSearchResult] {
        Self.fastTabListResults(from: FastTabListStore.shared.items)
    }

    /// Enter on a list item: the FastTab reader window, or the browser with Option held.
    func openFastTabListItem(_ result: BrowserSearchResult, route: FastTabListOpenRoute = .reader) {
        switch route {
        case .reader: MacReaderWindowRouter.shared.open(url: result.url, title: result.title)
        case .browser: openFastTabListItemInBrowser(url: result.url, title: result.title)
        }
    }

    /// Opens a list item's page in the browser the user is working in.
    func openFastTabListItemInBrowser(url: String, title: String) {
        guard let backend = resolvedWebSearchBackend() else { return }
        let openable = BrowserSearchResult(title: title, url: url, browserName: backend.appName,
                                           type: .bookmark, timestamp: Date())
        Task.detached(priority: .userInitiated) { backend.openURL(openable) }
    }

    /// "Read later" on a tab or bookmark row. Returns false when the link can't be saved.
    @discardableResult
    func readLater(_ result: BrowserSearchResult) -> Bool {
        guard FastTabListRowBridge.forResult(result) == .readLater else { return false }
        return FastTabListStore.shared.readLater(url: result.url, title: result.title)
    }

    /// "Move to Bookmarks" on a list item: writes the bookmark, and only once it landed
    /// moves the item to Trash. `completion` gets the folder label, or nil on failure.
    func moveFastTabListItemToBookmarks(_ result: BrowserSearchResult, completion: @escaping @MainActor (String?) -> Void) {
        guard result.type == .fastTabList, let itemID = result.bookmarkID,
              let item = FastTabListStore.shared.item(id: itemID) else { completion(nil); return }
        let writable = Set(backends.filter { $0 is ChromiumProfileAccess }.map(\.appName))
        guard let destination = FastTabListBookmarkDestination.choose(
            preferredBrowser: resolvedWebSearchBackend()?.appName,
            writableBrowsers: writable,
            bookmarks: cachedBookmarks
        ), let backend = backend(for: destination.browserName) else { completion(nil); return }

        let title = FastTabListBridge.bookmarkTitle(for: item)
        Task.detached(priority: .userInitiated) {
            let inserted = backend.insertBookmark(title: title, url: item.url, dateAdded: Date(),
                                                  profileName: destination.profileName, folderPath: [])
            await MainActor.run {
                guard inserted else { completion(nil); return }
                FastTabListStore.shared.moveToTrash(id: itemID)
                self.refetchCurrent()
                completion("\(destination.browserName) bookmarks")
            }
        }
    }
}
