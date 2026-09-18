import Foundation
import Testing
@testable import FastTab

struct BookmarkTreeStoreTests {
    @MainActor
    @Test func folderExpansionAndCollapse() {
        let suiteName = "test.fasttab.bookmark.expand.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BookmarkTreeStore(defaults: defaults)
        #expect(!store.isFolderExpanded("f1"))

        store.expandFolder("f1")
        #expect(store.isFolderExpanded("f1"))

        // Persisted to defaults
        let reloaded = BookmarkTreeStore(defaults: defaults)
        #expect(reloaded.isFolderExpanded("f1"))

        store.collapseFolder("f1")
        #expect(!store.isFolderExpanded("f1"))

        store.toggleFolder("f2")
        #expect(store.isFolderExpanded("f2"))
        store.toggleFolder("f2")
        #expect(!store.isFolderExpanded("f2"))
    }

    @MainActor
    @Test func flattenedProjectionWithLiveTabs() {
        let suiteName = "test.fasttab.bookmark.proj.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BookmarkTreeStore(defaults: defaults)

        let item1 = BookmarkItem(
            id: "b1",
            title: "GitHub",
            url: "https://github.com",
            browserName: "Google Chrome",
            profileName: "Default",
            dateAdded: nil,
            folderPath: "Favorites"
        )
        let item2 = BookmarkItem(
            id: "b2",
            title: "Apple",
            url: "https://apple.com",
            browserName: "Google Chrome",
            profileName: "Default",
            dateAdded: nil,
            folderPath: "Favorites"
        )

        let folder = BookmarkFolder(
            id: "f_favs",
            name: "Favorites",
            browserName: "Google Chrome",
            profileName: "Default",
            children: [.item(item1), .item(item2)]
        )

        store.setRootFolders([folder])

        // When folder is collapsed:
        let collapsedRows = store.flattenedRows(liveTabs: [])
        #expect(collapsedRows.count == 1)
        if case .folder(let id, let name, let depth, let isExp, let count, _) = collapsedRows[0] {
            #expect(id == "f_favs")
            #expect(name == "Favorites")
            #expect(depth == 0)
            #expect(!isExp)
            #expect(count == 2)
        } else {
            Issue.record("Expected folder row")
        }

        // When folder is expanded:
        store.expandFolder("f_favs")

        let liveGitHub = BrowserSearchResult(
            title: "GitHub",
            url: "https://github.com/",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            windowIndex: 1,
            tabIndex: 1,
            profileName: "Default",
            tabID: 101
        )

        let expandedRows = store.flattenedRows(liveTabs: [liveGitHub])
        #expect(expandedRows.count == 3) // folder + 2 items

        // Verify live match on GitHub
        if case .bookmark(let item, let depth, let match, _, _) = expandedRows[1] {
            #expect(item.id == "b1")
            #expect(depth == 1)
            #expect(match != nil)
            #expect(match?.tabID == 101)
        } else {
            Issue.record("Expected bookmark row 1")
        }

        // Verify Apple is not open
        if case .bookmark(let item, let depth, let match, _, _) = expandedRows[2] {
            #expect(item.id == "b2")
            #expect(depth == 1)
            #expect(match == nil)
        } else {
            Issue.record("Expected bookmark row 2")
        }
    }

    @MainActor
    @Test func compositeFolderExpansionAndToggle() {
        let suiteName = "test.fasttab.bookmark.composite.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BookmarkTreeStore(defaults: defaults)
        let compositeBarID = "Microsoft Edge|Profile 1|1"
        let compositeSubfolderID = "Microsoft Edge|Profile 1|2"

        // Default: raw "1" is expanded, so compositeBarID matches via raw ID fallback
        #expect(store.isFolderExpanded(compositeBarID))
        // Subfolder raw "2" is not expanded by default
        #expect(!store.isFolderExpanded(compositeSubfolderID))

        // Collapse bar
        store.collapseFolder(compositeBarID)
        #expect(!store.isFolderExpanded(compositeBarID))

        // Expand subfolder specifically
        store.expandFolder(compositeSubfolderID)
        #expect(store.isFolderExpanded(compositeSubfolderID))
    }

    @MainActor
    @Test func rowIDsAreUniqueAcrossProfiles() {
        let store = BookmarkTreeStore()

        let folderProf1 = BookmarkFolder(
            id: "Microsoft Edge|Profile 1|1",
            name: "Favorites Bar",
            browserName: "Microsoft Edge",
            profileName: "Profile 1",
            children: [
                .folder(
                    BookmarkFolder(
                        id: "Microsoft Edge|Profile 1|2",
                        name: "Break content",
                        browserName: "Microsoft Edge",
                        profileName: "Profile 1",
                        children: []
                    )
                )
            ]
        )

        let folderProf3 = BookmarkFolder(
            id: "Microsoft Edge|Profile 3|1",
            name: "Favorites Bar",
            browserName: "Microsoft Edge",
            profileName: "Profile 3",
            children: [
                .folder(
                    BookmarkFolder(
                        id: "Microsoft Edge|Profile 3|2",
                        name: "Other Favorites",
                        browserName: "Microsoft Edge",
                        profileName: "Profile 3",
                        children: []
                    )
                )
            ]
        )

        store.setRootFolders([folderProf1, folderProf3])
        store.expandFolder("Microsoft Edge|Profile 1|1")
        store.expandFolder("Microsoft Edge|Profile 3|1")

        let rows = store.flattenedRows(liveTabs: [])
        #expect(rows.count == 4)

        let rowIDs = rows.map(\.id)
        let uniqueIDs = Set(rowIDs)
        #expect(rowIDs.count == uniqueIDs.count)
    }

    @MainActor
    @Test func removeBookmarkRemovesItemAndUpdatesChildCount() {
        let store = BookmarkTreeStore()
        let item1 = BookmarkItem(
            id: "b1",
            title: "GitHub",
            url: "https://github.com",
            browserName: "Google Chrome",
            profileName: "Default",
            dateAdded: nil,
            folderPath: "Favorites"
        )
        let item2 = BookmarkItem(
            id: "b2",
            title: "Apple",
            url: "https://apple.com",
            browserName: "Google Chrome",
            profileName: "Default",
            dateAdded: nil,
            folderPath: "Favorites"
        )
        let folder = BookmarkFolder(
            id: "f1",
            name: "Favorites",
            browserName: "Google Chrome",
            profileName: "Default",
            children: [.item(item1), .item(item2)]
        )
        store.setRootFolders([folder])
        store.expandFolder("f1")

        #expect(store.flattenedRows(liveTabs: []).count == 3)
        #expect(store.rootFolders.first?.childCount == 2)

        let removed = store.removeBookmark(id: "b1")
        #expect(removed)
        #expect(store.rootFolders.first?.childCount == 1)

        let rowsAfter = store.flattenedRows(liveTabs: [])
        #expect(rowsAfter.count == 2)
        if case .bookmark(let remainingItem, _, _, _, _) = rowsAfter[1] {
            #expect(remainingItem.id == "b2")
        } else {
            Issue.record("Expected b2 to remain")
        }
    }

    @MainActor
    @Test func removeBookmarkInNestedSubfolder() {
        let store = BookmarkTreeStore()
        let item = BookmarkItem(
            id: "nested_bm",
            title: "Swift",
            url: "https://swift.org",
            browserName: "Safari",
            profileName: "Default",
            dateAdded: nil,
            folderPath: "Dev / Langs"
        )
        let subFolder = BookmarkFolder(
            id: "sub",
            name: "Langs",
            browserName: "Safari",
            profileName: "Default",
            children: [.item(item)]
        )
        let rootFolder = BookmarkFolder(
            id: "root",
            name: "Dev",
            browserName: "Safari",
            profileName: "Default",
            children: [.folder(subFolder)]
        )
        store.setRootFolders([rootFolder])
        store.expandFolder("root")
        store.expandFolder("sub")

        #expect(store.flattenedRows(liveTabs: []).count == 3)

        let removed = store.removeBookmark(id: "nested_bm")
        #expect(removed)

        let rowsAfter = store.flattenedRows(liveTabs: [])
        #expect(rowsAfter.count == 2) // root folder + empty subfolder
    }

    @MainActor
    @Test func deletingBookmarkIDsProjectsIsDeletingFlag() {
        let store = BookmarkTreeStore()
        let item = BookmarkItem(
            id: "del_target",
            title: "Target",
            url: "https://example.com",
            browserName: "Google Chrome",
            profileName: "Default",
            dateAdded: nil,
            folderPath: "Bookmarks"
        )
        let folder = BookmarkFolder(
            id: "f",
            name: "Bookmarks",
            browserName: "Google Chrome",
            profileName: "Default",
            children: [.item(item)]
        )
        store.setRootFolders([folder])
        store.expandFolder("f")

        let initialRows = store.flattenedRows(liveTabs: [])
        if case .bookmark(_, _, _, _, let isDeleting) = initialRows[1] {
            #expect(!isDeleting)
        } else {
            Issue.record("Expected bookmark row")
        }

        // Add to deleting set
        store.deletingBookmarkIDs.insert("del_target")
        let deletingRows = store.flattenedRows(liveTabs: [])
        if case .bookmark(_, _, _, _, let isDeleting) = deletingRows[1] {
            #expect(isDeleting)
        } else {
            Issue.record("Expected bookmark row with isDeleting")
        }

        // Once removed, deleting set cleared
        store.removeBookmark(id: "del_target")
        store.deletingBookmarkIDs.remove("del_target")
        #expect(store.flattenedRows(liveTabs: []).count == 1)
    }

    @MainActor
    @Test func multipleSimultaneousDeletions() {
        let store = BookmarkTreeStore()
        let items = (1...5).map { i in
            BookmarkItem(
                id: "item_\(i)",
                title: "Site \(i)",
                url: "https://site\(i).com",
                browserName: "Google Chrome",
                profileName: "Default",
                dateAdded: nil,
                folderPath: "Bookmarks"
            )
        }
        let folder = BookmarkFolder(
            id: "f",
            name: "Bookmarks",
            browserName: "Google Chrome",
            profileName: "Default",
            children: items.map { .item($0) }
        )
        store.setRootFolders([folder])
        store.expandFolder("f")

        // Mark items 1, 3, 5 as deleting concurrently
        store.deletingBookmarkIDs = ["item_1", "item_3", "item_5"]

        let rows = store.flattenedRows(liveTabs: [])
        #expect(rows.count == 6) // 1 folder + 5 items

        // Verify each row has correct isDeleting flag
        for row in rows.dropFirst() {
            if case .bookmark(let item, _, _, _, let isDeleting) = row {
                if ["item_1", "item_3", "item_5"].contains(item.id) {
                    #expect(isDeleting)
                } else {
                    #expect(!isDeleting)
                }
            }
        }

        // Concurrently remove them
        for id in ["item_1", "item_3", "item_5"] {
            store.removeBookmark(id: id)
            store.deletingBookmarkIDs.remove(id)
        }

        let remainingRows = store.flattenedRows(liveTabs: [])
        #expect(remainingRows.count == 3) // 1 folder + items 2 and 4
    }

    @MainActor
    @Test func profileScopedBookmarkRemovalWithDuplicateIDs() {
        let store = BookmarkTreeStore()
        let itemChrome = BookmarkItem(
            id: "1",
            title: "Chrome Site",
            url: "https://chrome.com",
            browserName: "Google Chrome",
            profileName: "Profile 1",
            dateAdded: nil,
            folderPath: "Bookmarks"
        )
        let itemBrave = BookmarkItem(
            id: "1",
            title: "Brave Site",
            url: "https://brave.com",
            browserName: "Brave Browser",
            profileName: "Default",
            dateAdded: nil,
            folderPath: "Bookmarks"
        )
        let folderChrome = BookmarkFolder(
            id: "f_chrome",
            name: "Chrome Bookmarks",
            browserName: "Google Chrome",
            profileName: "Profile 1",
            children: [.item(itemChrome)]
        )
        let folderBrave = BookmarkFolder(
            id: "f_brave",
            name: "Brave Bookmarks",
            browserName: "Brave Browser",
            profileName: "Default",
            children: [.item(itemBrave)]
        )
        store.setRootFolders([folderChrome, folderBrave])
        store.expandFolder("f_chrome")
        store.expandFolder("f_brave")

        #expect(itemChrome.uniqueKey != itemBrave.uniqueKey)

        // Remove only the Chrome bookmark with id "1"
        let removed = store.removeBookmark(id: "1", browserName: "Google Chrome", profileName: "Profile 1")
        #expect(removed)

        let rows = store.flattenedRows(liveTabs: [])
        // Chrome folder should now be empty (childCount 0), Brave folder should still contain its item
        #expect(rows.contains { row in
            if case .bookmark(let item, _, _, _, _) = row {
                return item.browserName == "Brave Browser" && item.id == "1"
            }
            return false
        })
        #expect(!rows.contains { row in
            if case .bookmark(let item, _, _, _, _) = row {
                return item.browserName == "Google Chrome" && item.id == "1"
            }
            return false
        })
    }
}
