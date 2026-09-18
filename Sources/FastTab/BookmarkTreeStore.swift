import Foundation
import AppKit
import OSLog

@MainActor
final class BookmarkTreeStore: ObservableObject {
    static let shared = BookmarkTreeStore()

    static let expandedFolderIDsKey = "FastTab.bookmarks.expandedFolderIDs"
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "BookmarkTreeStore")
    private let defaults: UserDefaults

    @Published private(set) var rootFolders: [BookmarkFolder] = []
    @Published private(set) var expandedFolderIDs: Set<String> = []
    @Published var armedBookmarkID: String? = nil
    @Published var deletingBookmarkIDs: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.stringArray(forKey: Self.expandedFolderIDsKey) {
            self.expandedFolderIDs = Set(saved)
        } else {
            // Default: expand top-level folders
            self.expandedFolderIDs = ["bookmark_bar", "Bookmarks Bar", "Favorites", "Favorites Bar", "1"]
        }
    }

    func setRootFolders(_ folders: [BookmarkFolder]) {
        self.rootFolders = folders
    }

    @discardableResult
    func removeBookmark(id: String, browserName: String? = nil, profileName: String? = nil) -> Bool {
        var didRemove = false
        for i in rootFolders.indices {
            if let browserName, !browserName.isEmpty, rootFolders[i].browserName != browserName {
                continue
            }
            if let profileName, !profileName.isEmpty, rootFolders[i].profileName != profileName {
                continue
            }
            if rootFolders[i].removeBookmark(id: id) {
                didRemove = true
            }
        }
        return didRemove
    }

    func toggleFolder(_ folderID: String) {
        if isFolderExpanded(folderID) {
            collapseFolder(folderID)
        } else {
            expandFolder(folderID)
        }
    }

    func expandFolder(_ folderID: String) {
        guard !expandedFolderIDs.contains(folderID) else { return }
        expandedFolderIDs.insert(folderID)
        persistExpandedIDs()
    }

    func collapseFolder(_ folderID: String) {
        expandedFolderIDs.remove(folderID)
        if let rawID = folderID.split(separator: "|").last.map(String.init) {
            expandedFolderIDs.remove(rawID)
        }
        persistExpandedIDs()
    }

    func isFolderExpanded(_ folderID: String) -> Bool {
        if expandedFolderIDs.contains(folderID) {
            return true
        }
        if let rawID = folderID.split(separator: "|").last.map(String.init), expandedFolderIDs.contains(rawID) {
            return true
        }
        return false
    }

    private func persistExpandedIDs() {
        defaults.set(Array(expandedFolderIDs), forKey: Self.expandedFolderIDsKey)
    }

    /// Pure projection of visible rows based on expanded folder state and live tabs
    func flattenedRows(liveTabs: [BrowserSearchResult]) -> [BookmarkDisplayRow] {
        var rows: [BookmarkDisplayRow] = []

        func visit(nodes: [BookmarkTreeNode], depth: Int) {
            for node in nodes {
                switch node {
                case .folder(let folder):
                    let isExpanded = isFolderExpanded(folder.id)
                    rows.append(
                        .folder(
                            id: folder.id,
                            name: folder.name,
                            depth: depth,
                            isExpanded: isExpanded,
                            childCount: folder.childCount,
                            browserName: folder.browserName
                        )
                    )
                    if isExpanded {
                        visit(nodes: folder.children, depth: depth + 1)
                    }
                case .item(let item):
                    let match = MyOrderReconciler.findMatchingLiveTab(
                        url: item.url,
                        profileName: item.profileName,
                        browserName: item.browserName,
                        in: liveTabs
                    )
                    rows.append(
                        .bookmark(
                            item: item,
                            depth: depth,
                            matchingLiveTab: match,
                            isArmedForDelete: armedBookmarkID == item.uniqueKey || armedBookmarkID == item.id,
                            isDeleting: deletingBookmarkIDs.contains(item.uniqueKey) || deletingBookmarkIDs.contains(item.id)
                        )
                    )
                }
            }
        }

        visit(nodes: rootFolders.map { .folder($0) }, depth: 0)
        return rows
    }
}
