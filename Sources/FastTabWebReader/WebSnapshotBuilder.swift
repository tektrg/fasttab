import FastTabSync
import Foundation

/// What the Mac knows right now, in plain values (the app adapts its stores into this).
public struct WebSnapshotInput: Sendable {
    public struct Tab: Sendable, Equatable {
        public var browserName: String
        public var profileName: String?
        public var windowIndex: Int?
        public var tabIndex: Int?
        public var tabID: Int?
        public var url: String
        public var title: String
        public var lastActiveAt: Date?

        public init(browserName: String, profileName: String? = nil, windowIndex: Int? = nil, tabIndex: Int? = nil,
                    tabID: Int? = nil, url: String, title: String, lastActiveAt: Date? = nil) {
            self.browserName = browserName
            self.profileName = profileName
            self.windowIndex = windowIndex
            self.tabIndex = tabIndex
            self.tabID = tabID
            self.url = url
            self.title = title
            self.lastActiveAt = lastActiveAt
        }
    }

    public struct Bookmark: Sendable, Equatable {
        public var id: String
        public var browserName: String
        public var profileName: String?
        /// `Bookmarks Bar/Reading/Rust` style; nil = top level.
        public var folderPath: String?
        public var title: String
        public var url: String

        public init(id: String, browserName: String, profileName: String? = nil, folderPath: String? = nil,
                    title: String, url: String) {
            self.id = id
            self.browserName = browserName
            self.profileName = profileName
            self.folderPath = folderPath
            self.title = title
            self.url = url
        }
    }

    /// A reader article this Mac has extracted (Readability output).
    public struct Article: Sendable, Equatable {
        public var url: String
        public var title: String
        public var byline: String?
        public var html: String
        public var extractedAt: Date

        public init(url: String, title: String, byline: String?, html: String, extractedAt: Date) {
            self.url = url
            self.title = title
            self.byline = byline
            self.html = html
            self.extractedAt = extractedAt
        }
    }

    public var macName: String
    public var tabs: [Tab]
    public var bookmarks: [Bookmark]
    public var listItems: [SavedOnIPhoneLink]
    public var articles: [Article]

    public init(macName: String, tabs: [Tab], bookmarks: [Bookmark], listItems: [SavedOnIPhoneLink], articles: [Article]) {
        self.macName = macName
        self.tabs = tabs
        self.bookmarks = bookmarks
        self.listItems = listItems
        self.articles = articles
    }
}

/// The snapshot plus the article bodies it indexes (each uploaded as its own blob).
public struct WebSnapshotBuild: Sendable {
    public var snapshot: WebSnapshot
    /// Article id → encoded `WebArticleBody` (its SHA-256 is the index's `contentHash`).
    public var articleBodies: [String: Data]
}

/// Pure: input → `fasttab.web.snapshot/1` + article bodies, within the contract's limits.
public enum WebSnapshotBuilder {
    public static let maxSnapshotBytes = 5 * 1024 * 1024
    public static let maxArticleBytes = 2 * 1024 * 1024
    public static let maxArticles = 500

    public static let upNextListID = "up-next"
    public static let fastTabListID = "fasttab-list"

    public static func build(_ input: WebSnapshotInput, now: Date = Date()) -> WebSnapshotBuild {
        let (articles, bodies) = buildArticles(input.articles)
        let articleIDs = Set(articles.map(\.id))
        var snapshot = WebSnapshot(
            generatedAt: WebReaderJSON.iso(now),
            macName: input.macName,
            windows: buildWindows(input.tabs),
            bookmarks: buildBookmarks(input.bookmarks),
            lists: buildLists(input.listItems, articleIDs: articleIDs),
            articles: articles
        )
        // Over the cap (huge bookmark trees): bookmarks go first, then the oldest list items.
        if encodedSize(snapshot) > maxSnapshotBytes {
            snapshot.bookmarks.children = []
        }
        while encodedSize(snapshot) > maxSnapshotBytes,
              let index = snapshot.lists.indices.max(by: { snapshot.lists[$0].items.count < snapshot.lists[$1].items.count }),
              !snapshot.lists[index].items.isEmpty {
            snapshot.lists[index].items.removeLast(max(1, snapshot.lists[index].items.count / 4))
        }
        return WebSnapshotBuild(snapshot: snapshot, articleBodies: bodies)
    }

    static func encodedSize(_ snapshot: WebSnapshot) -> Int {
        (try? WebReaderJSON.encoder.encode(snapshot).count) ?? .max
    }

    // MARK: - Windows

    /// One window per (browser, profile, window index), in browser then window order; tabs in
    /// tab order. Ids are stable across snapshots for the same window/tab.
    static func buildWindows(_ tabs: [WebSnapshotInput.Tab]) -> [WebSnapshot.Window] {
        struct Key: Hashable, Comparable {
            let browser: String, profile: String, window: Int
            static func < (a: Key, b: Key) -> Bool {
                (a.browser, a.profile, a.window) < (b.browser, b.profile, b.window)
            }
        }
        let grouped = Dictionary(grouping: tabs.filter { isWebURL($0.url) }) {
            Key(browser: $0.browserName, profile: $0.profileName ?? "", window: $0.windowIndex ?? 0)
        }
        return grouped.keys.sorted().map { key in
            let windowID = [key.browser, key.profile, String(key.window)].joined(separator: ":")
            let sorted = grouped[key, default: []].sorted { ($0.tabIndex ?? .max, $0.url) < ($1.tabIndex ?? .max, $1.url) }
            return WebSnapshot.Window(id: windowID, tabs: sorted.enumerated().map { offset, tab in
                WebSnapshot.Tab(
                    id: windowID + ":" + (tab.tabID.map(String.init) ?? "i\(tab.tabIndex ?? offset)"),
                    url: tab.url,
                    title: tab.title.isEmpty ? tab.url : tab.title,
                    favIconUrl: nil,
                    lastActiveAt: tab.lastActiveAt.map(WebReaderJSON.iso)
                )
            })
        }
    }

    // MARK: - Bookmarks

    /// A root folder → one folder per browser (and profile, when more than one) → the
    /// `folderPath` folders → bookmarks, in input order.
    static func buildBookmarks(_ bookmarks: [WebSnapshotInput.Bookmark]) -> WebSnapshot.BookmarkNode {
        final class Folder {
            let id: String, title: String
            var children: [Any] = []
            var subfolders: [String: Folder] = [:]
            init(id: String, title: String) { self.id = id; self.title = title }
            func folder(_ title: String) -> Folder {
                if let existing = subfolders[title] { return existing }
                let created = Folder(id: id + "/" + title, title: title)
                subfolders[title] = created
                children.append(created)
                return created
            }
            var node: WebSnapshot.BookmarkNode {
                WebSnapshot.BookmarkNode(id: id, title: title, url: nil, children: children.map {
                    ($0 as? Folder)?.node ?? ($0 as! WebSnapshot.BookmarkNode)
                })
            }
        }
        let root = Folder(id: "root", title: "Bookmarks")
        let profilesPerBrowser = Dictionary(grouping: bookmarks, by: \.browserName).mapValues { Set($0.map { $0.profileName ?? "" }).count }
        for bookmark in bookmarks where isWebURL(bookmark.url) {
            var folder = root.folder(bookmark.browserName)
            if (profilesPerBrowser[bookmark.browserName] ?? 0) > 1 {
                folder = folder.folder(bookmark.profileName ?? "Default")
            }
            for part in (bookmark.folderPath ?? "").split(separator: "/") where !part.isEmpty {
                folder = folder.folder(String(part))
            }
            folder.children.append(WebSnapshot.BookmarkNode(
                id: "bm:" + bookmark.id, title: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                url: bookmark.url, children: nil))
        }
        return root.node
    }

    // MARK: - Lists

    /// "Up Next" = unread FastTab List items; "FastTab List" = every live item. Newest first.
    static func buildLists(_ items: [SavedOnIPhoneLink], articleIDs: Set<String>) -> [WebSnapshot.List] {
        let live = items.filter { !$0.isTrashed && !$0.isPurged }.sorted { $0.savedAt > $1.savedAt }
        func item(_ link: SavedOnIPhoneLink) -> WebSnapshot.ListItem {
            let articleID = WebReaderJSON.articleID(for: link.url)
            return WebSnapshot.ListItem(
                id: link.id, url: link.url, title: link.title ?? link.url,
                addedAt: WebReaderJSON.iso(link.savedAt),
                articleId: articleIDs.contains(articleID) ? articleID : nil)
        }
        return [
            WebSnapshot.List(id: upNextListID, name: "Up Next", kind: "upNext", items: live.filter { !$0.isRead }.map(item)),
            WebSnapshot.List(id: fastTabListID, name: "FastTab List", kind: "list", items: live.map(item))
        ]
    }

    // MARK: - Articles

    /// Newest `maxArticles` (by extraction) whose body fits `maxArticleBytes`; one per article id.
    static func buildArticles(_ articles: [WebSnapshotInput.Article]) -> ([WebSnapshot.Article], [String: Data]) {
        var index: [WebSnapshot.Article] = []
        var bodies: [String: Data] = [:]
        for article in articles.sorted(by: { $0.extractedAt > $1.extractedAt }) {
            guard index.count < maxArticles, isWebURL(article.url) else { continue }
            let id = WebReaderJSON.articleID(for: article.url)
            guard bodies[id] == nil else { continue }
            let body = WebArticleBody(
                url: article.url, title: article.title, byline: article.byline?.nilIfBlank,
                html: article.html, textLength: plainTextLength(article.html))
            guard let data = try? body.encoded(), data.count <= maxArticleBytes else { continue }
            bodies[id] = data
            index.append(WebSnapshot.Article(
                id: id, url: article.url, title: article.title, byline: body.byline,
                contentHash: WebReaderJSON.sha256Hex(data), size: data.count))
        }
        return (index, bodies)
    }

    static func plainTextLength(_ html: String) -> Int {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).count
    }

    static func isWebURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
