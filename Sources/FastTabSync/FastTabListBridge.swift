import Foundation

/// The two bridges between the **FastTab List** (to read, FastTab-owned) and browser
/// **Bookmarks** (to keep, browser-owned), as plain rules shared by the Mac command bar
/// and the phone:
/// - "Read later" on a bookmark or open tab → a new list item (`readLaterLink`).
/// - "Move to Bookmarks" on a list item → a browser bookmark, then the item goes to Trash.
///   Only offered when a Mac is connected (`offersMoveToBookmarks`).
public enum FastTabListBridge {
    /// A list item for "Read later", or nil when the link can't be read later (only
    /// web pages can: no `file:`, `about:`, `chrome:` or bare text).
    public static func readLaterLink(url urlString: String, title: String?, now: Date = Date()) -> SavedOnIPhoneLink? {
        guard isReadableWebURL(urlString) else { return nil }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SavedOnIPhoneLink(
            url: urlString,
            title: (trimmedTitle?.isEmpty ?? true) ? nil : trimmedTitle,
            savedAt: now
        )
    }

    public static func isReadableWebURL(_ urlString: String) -> Bool {
        guard let scheme = URL(string: urlString)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Bookmarks need a name: the item's title, else its website, else the raw URL.
    public static func bookmarkTitle(for link: SavedOnIPhoneLink) -> String {
        if let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return domain(of: link.url) ?? link.url
    }

    /// Move to Bookmarks writes into the user's browser, which only a connected Mac can do.
    public static func offersMoveToBookmarks(isStandalone: Bool) -> Bool {
        !isStandalone
    }

    /// "example.com" (no `www.`), or nil for a URL without a host.
    public static func domain(of urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Short reading-state hint for a row: "Read", "40% read", or nil for unread/unstarted.
    /// With a read count: "Read 3×" (read), "40% · Read 2×" (rereading).
    public static func progressHint(for link: SavedOnIPhoneLink) -> String? {
        let percent = Int((link.progress * 100).rounded())
        if let countText = ReadProgressText.readCount(link.readCount) {
            return (link.isRead || percent < 1) ? countText : "\(percent)% · \(countText)"
        }
        if link.isRead { return "Read" }
        return percent >= 1 ? "\(percent)% read" : nil
    }
}
