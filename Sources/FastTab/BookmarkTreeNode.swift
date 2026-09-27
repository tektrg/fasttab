import Foundation
import FastTabSync

enum BookmarkTreeNode: Identifiable, Equatable, Sendable {
    case folder(BookmarkFolder)
    case item(BookmarkItem)

    var id: String {
        switch self {
        case .folder(let folder): return folder.id
        case .item(let item): return item.id
        }
    }
}

struct BookmarkFolder: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let browserName: String
    let profileName: String
    var children: [BookmarkTreeNode]

    var childCount: Int {
        children.count
    }

    @discardableResult
    mutating func removeBookmark(id: String) -> Bool {
        var didRemove = false
        var newChildren: [BookmarkTreeNode] = []
        for child in children {
            switch child {
            case .item(let item):
                if item.id == id {
                    didRemove = true
                } else {
                    newChildren.append(child)
                }
            case .folder(var subFolder):
                if subFolder.removeBookmark(id: id) {
                    didRemove = true
                }
                newChildren.append(.folder(subFolder))
            }
        }
        if didRemove {
            self.children = newChildren
        }
        return didRemove
    }
}

struct BookmarkItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let url: String
    let browserName: String
    let profileName: String
    let dateAdded: Date?
    let folderPath: String

    var uniqueKey: String {
        "\(browserName)|\(profileName)|\(id)"
    }

    var asSearchResult: BrowserSearchResult {
        BrowserSearchResult(
            title: title,
            url: url,
            browserName: browserName,
            type: .bookmark,
            timestamp: dateAdded ?? Date(timeIntervalSince1970: 0),
            bookmarkID: id,
            profileName: profileName,
            folderPath: folderPath
        )
    }
}

enum BookmarkDisplayRow: Identifiable, Equatable, Sendable {
    case folder(id: String, name: String, depth: Int, isExpanded: Bool, childCount: Int, browserName: String)
    case bookmark(item: BookmarkItem, depth: Int, matchingLiveTab: BrowserSearchResult?, isArmedForDelete: Bool, isDeleting: Bool)

    var id: String {
        switch self {
        case .folder(let id, _, _, _, _, _):
            return "bm_folder_\(id)"
        case .bookmark(let item, _, _, _, _):
            return "bm_item_\(item.browserName)_\(item.profileName)_\(item.id)_\(item.url)"
        }
    }

    var depth: Int {
        switch self {
        case .folder(_, _, let depth, _, _, _): return depth
        case .bookmark(_, let depth, _, _, _): return depth
        }
    }
}

extension BookmarkDisplayRow {
    /// The Settings > Bookmarks filter: bookmark rows whose title or URL contains
    /// every typed word, folded like every other Fast Tab search (`SyncSearchQuery`,
    /// so "don hang" finds "Đơn hàng"). Folder rows drop out while filtering.
    /// A query with no letters or digits leaves `rows` unchanged.
    static func filter(_ rows: [BookmarkDisplayRow], matching query: String) -> [BookmarkDisplayRow] {
        let searchQuery = SyncSearchQuery(query)
        guard !searchQuery.words.isEmpty else { return rows }
        return rows.filter { row in
            guard case .bookmark(let item, _, _, _, _) = row else { return false }
            return searchQuery.matches(title: item.title, url: item.url)
        }
    }
}
