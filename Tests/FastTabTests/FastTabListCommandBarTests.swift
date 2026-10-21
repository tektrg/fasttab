import Foundation
import Testing
import IndieSearch
@testable import FastTab
@testable import FastTabSync

/// FastTab List in the Mac command bar: rows, search, `@FastTab List` scope, bridges,
/// and the Mac store's sync seam. Pure logic plus a temp-file store; no CloudKit, no UI.
@MainActor
@Suite("FastTab List in the command bar")
struct FastTabListCommandBarTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func link(_ url: String, title: String? = nil, progress: Double = 0, read: Bool = false,
                      trashed: Bool = false) -> SavedOnIPhoneLink {
        SavedOnIPhoneLink(
            id: FastTabListLibrary.itemID(for: url), url: url, title: title, savedAt: now,
            deletedAt: trashed ? now : nil, readAt: read ? now : nil, progress: progress
        )
    }

    private func row(_ type: BrowserResultType, url: String, browser: String = "Google Chrome",
                     profile: String? = "Default", isGhost: Bool = false) -> BrowserSearchResult {
        BrowserSearchResult(title: "T", url: url, browserName: browser, type: type, timestamp: now,
                            profileName: profile, isGhost: isGhost)
    }

    // MARK: Rows

    @Test func rowsShowTitleDomainAndReadingHintAndSkipTrash() {
        let rows = BrowserTabService.fastTabListResults(from: [
            link("https://www.example.com/a", title: "Article A", progress: 0.4),
            link("https://news.site/b", read: true),
            link("https://plain.org/c"),
            link("https://gone.org/d", trashed: true)
        ])
        #expect(rows.count == 3)
        let byURL = Dictionary(uniqueKeysWithValues: rows.map { ($0.url, $0) })
        #expect(byURL["https://www.example.com/a"]?.title == "Article A")
        #expect(byURL["https://www.example.com/a"]?.secondaryBaseText == "example.com • 40% read")
        #expect(byURL["https://news.site/b"]?.title == "news.site")
        #expect(byURL["https://news.site/b"]?.secondaryBaseText == "news.site • Read")
        #expect(byURL["https://plain.org/c"]?.secondaryBaseText == "plain.org")
        #expect(rows.allSatisfy { $0.type == .fastTabList && $0.bookmarkID != nil })
    }

    @Test func rowsMatchTypedWordsLikeOtherResults() {
        let rows = BrowserTabService.fastTabListResults(from: [
            link("https://example.com/swift-concurrency", title: "Swift Concurrency Guide"),
            link("https://example.com/cooking", title: "Pasta at home")
        ])
        let words = searchWords(in: "concurrency swift")
        #expect(rows.filter { $0.matches(words: words) }.map(\.title) == ["Swift Concurrency Guide"])
    }

    @Test func listRowsNeverCollapseIntoTheSamePageOpenAsATab() {
        let url = "https://example.com/post"
        let tab = row(.tab, url: url)
        let listRow = BrowserTabService.fastTabListResults(from: [link(url, title: "T")])[0]
        let merged = deduplicatingSamePages([tab, listRow], frecencyScore: { _ in 0 })
        #expect(merged.count == 2)
    }

    @Test func listRowsStayOutOfRecents() {
        let listRow = BrowserTabService.fastTabListResults(from: [link("https://a.com/x")])[0]
        #expect(sortQuickOpenResults([listRow, row(.tab, url: "https://b.com")]).map(\.type) == [.tab])
    }

    // MARK: Scope

    @Test func fastTabListScopeKeepsOnlyListItems() {
        let filter = ScopeFilter.from(chips: [ScopeChip(kind: .fastTabList)])
        let listRow = BrowserTabService.fastTabListResults(from: [link("https://a.com/x")])[0]
        #expect(filter.requiredType == .fastTabList)
        #expect(filter.matches(listRow))
        #expect(!filter.matches(row(.bookmark, url: "https://a.com/x")))
        #expect(!filter.matches(row(.tab, url: "https://a.com/x")))
    }

    @Test func fastTabListScopeConflictsWithAnotherType() {
        let filter = ScopeFilter.from(chips: [ScopeChip(kind: .fastTabList), ScopeChip(kind: .bookmarks)])
        #expect(!filter.isSatisfiable)
    }

    @Test func scopeIsOfferedInTheAtMenu() {
        #expect(RootSuggestion.fastTabList.label == "FastTab List")
        #expect(ScopeChip(kind: .fastTabList).displayLabel == "FastTab List")
    }

    // MARK: Bridges

    @Test func bridgeOfferedPerRowType() {
        #expect(FastTabListRowBridge.forResult(row(.tab, url: "https://a.com")) == .readLater)
        #expect(FastTabListRowBridge.forResult(row(.bookmark, url: "http://a.com")) == .readLater)
        #expect(FastTabListRowBridge.forResult(row(.tab, url: "file:///Users/x", browser: "Finder")) == nil)
        #expect(FastTabListRowBridge.forResult(row(.tab, url: "https://a.com", isGhost: true)) == nil)
        #expect(FastTabListRowBridge.forResult(row(.history, url: "https://a.com")) == nil)
        #expect(FastTabListRowBridge.forResult(row(.sent, url: "https://a.com")) == nil)
        let listRow = BrowserTabService.fastTabListResults(from: [link("https://a.com/x")])[0]
        #expect(FastTabListRowBridge.forResult(listRow) == .moveToBookmarks)
    }

    @Test func moveToBookmarksPrefersTheCurrentBrowserThenTheBusiestProfile() {
        let bookmarks = [
            row(.bookmark, url: "https://1", browser: "Google Chrome", profile: "Work"),
            row(.bookmark, url: "https://2", browser: "Google Chrome", profile: "Default"),
            row(.bookmark, url: "https://3", browser: "Google Chrome", profile: "Default"),
            row(.bookmark, url: "https://4", browser: "Arc", profile: "Default"),
            row(.bookmark, url: "https://5", browser: "Safari", profile: nil)
        ]
        let writable: Set = ["Google Chrome", "Arc"]
        #expect(FastTabListBookmarkDestination.choose(preferredBrowser: "Arc", writableBrowsers: writable, bookmarks: bookmarks)
                == FastTabListBookmarkDestination(browserName: "Arc", profileName: "Default"))
        #expect(FastTabListBookmarkDestination.choose(preferredBrowser: "Safari", writableBrowsers: writable, bookmarks: bookmarks)
                == FastTabListBookmarkDestination(browserName: "Google Chrome", profileName: "Default"))
        #expect(FastTabListBookmarkDestination.choose(preferredBrowser: nil, writableBrowsers: [], bookmarks: bookmarks) == nil)
    }

    // MARK: Mac store

    private func makeStore() -> FastTabListStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "FastTabListCommandBarTests.\(UUID().uuidString)")!
        return FastTabListStore(fileStore: FastTabListFileStore(fileURL: dir.appendingPathComponent("list.json"),
                                                                 defaults: defaults),
                                now: { self.now })
    }

    @Test func readLaterSavesWebLinksOnceAndRefusesOthers() {
        let store = makeStore()
        #expect(store.readLater(url: "https://example.com/a", title: "  A  "))
        #expect(store.readLater(url: "https://EXAMPLE.com/a", title: nil))
        #expect(!store.readLater(url: "file:///tmp/x", title: "x"))
        #expect(!store.readLater(url: "$(echo INJECTED)", title: "x"))
        #expect(store.items.count == 1)
        #expect(store.items.first?.title == "A")
    }

    @Test func trashAndRestoreAreLocalEditsThatSync() {
        let store = makeStore()
        store.readLater(url: "https://example.com/a", title: "A")
        let id = store.items[0].id
        var announced = 0
        let observer = NotificationCenter.default.addObserver(forName: .fastTabListDidChangeLocally, object: nil, queue: nil) { _ in
            announced += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.moveToTrash(id: id)
        #expect(store.items.isEmpty)
        #expect(store.listItemsForSync().first?.isTrashed == true)
        store.restore(id: id)
        #expect(store.items.count == 1)
        #expect(announced == 2)
    }

    @Test func remoteItemsAppearWithoutEchoingBack() {
        let store = makeStore()
        var announced = 0
        let observer = NotificationCenter.default.addObserver(forName: .fastTabListDidChangeLocally, object: nil, queue: nil) { _ in
            announced += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let remote = link("https://phone.example/read", title: "From phone", progress: 0.5)
        store.applyRemoteListItem(remote)
        #expect(store.items.map(\.title) == ["From phone"])
        store.removeRemoteListItem(id: remote.id)
        #expect(store.items.isEmpty)
        #expect(announced == 0)
    }
}
