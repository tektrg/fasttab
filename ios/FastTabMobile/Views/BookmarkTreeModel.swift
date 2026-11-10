import SwiftUI
import FastTabSync

/// Which browser/profile/Mac a bookmark leaf came from, before its blob's
/// bookmarks were merged into the shared folder tree. Needed to send a delete
/// command back to the right place — the tree itself has no other memory of it.
public struct BookmarkSource: Sendable, Hashable {
    public let deviceID: String
    public let browserName: String
    public let profileName: String

    /// Matches `SyncedBookmarkBlob.id`'s own derivation. `SyncedBookmarkItem.id`
    /// is only unique *within* a blob — Chromium's own bookmark ids are small
    /// integers assigned independently per profile, and Safari falls back to the
    /// raw URL — so anything keying off a bookmark id alone must pair it with
    /// this to avoid colliding with an unrelated bookmark in another blob.
    public var blobID: String { "\(deviceID)|\(browserName)|\(profileName)" }
}

public struct BookmarkTreeNode: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: String?
    public let source: BookmarkSource?
    public let isFolder: Bool
    public var children: [BookmarkTreeNode]?
    public var bookmarkItem: SyncedBookmarkItem?
    public var totalCount: Int

    public init(
        id: String,
        title: String,
        url: String? = nil,
        source: BookmarkSource? = nil,
        isFolder: Bool,
        children: [BookmarkTreeNode]? = nil,
        bookmarkItem: SyncedBookmarkItem? = nil,
        totalCount: Int = 1
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.source = source
        self.isFolder = isFolder
        self.children = children
        self.bookmarkItem = bookmarkItem
        self.totalCount = totalCount
    }
}

public enum BookmarkTreeBuilder {
    private final class MutableFolderNode {
        let name: String
        var subfolders: [String: MutableFolderNode] = [:]
        var bookmarks: [(source: BookmarkSource, item: SyncedBookmarkItem)] = []

        init(name: String) {
            self.name = name
        }

        func insert(pathComponents: [String], source: BookmarkSource, bookmark: SyncedBookmarkItem) {
            if pathComponents.isEmpty {
                // Empty URL indicates a folder marker rather than a real bookmark leaf
                if !bookmark.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bookmarks.append((source, bookmark))
                }
            } else {
                let first = pathComponents[0]
                let rest = Array(pathComponents.dropFirst())
                let sub = subfolders[first] ?? MutableFolderNode(name: first)
                subfolders[first] = sub
                sub.insert(pathComponents: rest, source: source, bookmark: bookmark)
            }
        }

        func toTreeNode(idPrefix: String = "") -> BookmarkTreeNode {
            let currentID = idPrefix.isEmpty ? name : "\(idPrefix)/\(name)"

            let sortedFolderKeys = subfolders.keys.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            let folderChildren = sortedFolderKeys.compactMap { subfolders[$0]?.toTreeNode(idPrefix: currentID) }

            let bookmarkChildren = bookmarks.sorted {
                $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending
            }.map { entry in
                BookmarkTreeNode(
                    id: "bm_\(entry.source.blobID)#\(entry.item.id)",
                    title: entry.item.title.isEmpty ? entry.item.url : entry.item.title,
                    url: entry.item.url,
                    source: entry.source,
                    isFolder: false,
                    children: nil,
                    bookmarkItem: entry.item,
                    totalCount: 1
                )
            }

            let allChildren = folderChildren + bookmarkChildren
            let count = allChildren.reduce(0) { $0 + $1.totalCount }

            return BookmarkTreeNode(
                id: "folder_\(currentID)",
                title: name,
                url: nil,
                source: nil,
                isFolder: true,
                children: allChildren.isEmpty ? nil : allChildren,
                bookmarkItem: nil,
                totalCount: count
            )
        }
    }

    public static func splitPath(_ path: String) -> [String] {
        let normalized = path
            .replacingOccurrences(of: " / ", with: "/")
            .replacingOccurrences(of: " > ", with: "/")
            .replacingOccurrences(of: "\\", with: "/")
        return normalized
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func buildTree(from blobs: [SyncedBookmarkBlob]) -> [BookmarkTreeNode] {
        let root = MutableFolderNode(name: "root")
        var unfiledItems: [(source: BookmarkSource, item: SyncedBookmarkItem)] = []

        for blob in blobs {
            let source = BookmarkSource(deviceID: blob.deviceID, browserName: blob.browserName, profileName: blob.profileName)
            for bm in blob.bookmarks {
                let rawPath = bm.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hasValidURL = !bm.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if rawPath.isEmpty {
                    if hasValidURL {
                        unfiledItems.append((source, bm))
                    }
                } else {
                    let components = splitPath(rawPath)
                    if components.isEmpty {
                        if hasValidURL {
                            unfiledItems.append((source, bm))
                        }
                    } else {
                        root.insert(pathComponents: components, source: source, bookmark: bm)
                    }
                }
            }
        }

        let sortedFolderKeys = root.subfolders.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        var topNodes = sortedFolderKeys.compactMap { root.subfolders[$0]?.toTreeNode() }

        if !root.bookmarks.isEmpty {
            let rootBms = root.bookmarks.map { entry in
                BookmarkTreeNode(
                    id: "bm_\(entry.source.blobID)#\(entry.item.id)",
                    title: entry.item.title.isEmpty ? entry.item.url : entry.item.title,
                    url: entry.item.url,
                    source: entry.source,
                    isFolder: false,
                    bookmarkItem: entry.item,
                    totalCount: 1
                )
            }
            topNodes.append(contentsOf: rootBms)
        }

        if !unfiledItems.isEmpty {
            let unfiledNodes = unfiledItems.map { entry in
                BookmarkTreeNode(
                    id: "bm_\(entry.source.blobID)#\(entry.item.id)",
                    title: entry.item.title.isEmpty ? entry.item.url : entry.item.title,
                    url: entry.item.url,
                    source: entry.source,
                    isFolder: false,
                    children: nil,
                    bookmarkItem: entry.item,
                    totalCount: 1
                )
            }
            topNodes.append(BookmarkTreeNode(
                // Deliberately not a plausible folder path: real folder names
                // can't contain "/", so no real folder can ever collide with
                // this id the way "unfiled" could.
                id: "folder_$synthetic/unfiled",
                title: "Other Bookmarks",
                url: nil,
                source: nil,
                isFolder: true,
                children: unfiledNodes,
                bookmarkItem: nil,
                totalCount: unfiledNodes.count
            ))
        }

        return topNodes
    }

    /// The Bookmarks tab filter, folded like the other iOS search screens
    /// (`SyncSearchQuery`, so "don hang" finds "Đơn hàng"). A bookmark stays when
    /// its title or URL contains every typed word; a folder stays when its name
    /// matches or any descendant does, showing only the matching children when
    /// there are some. A query with no letters or digits returns `nodes` unchanged.
    public static func filter(_ nodes: [BookmarkTreeNode], matching query: String) -> [BookmarkTreeNode] {
        let searchQuery = SyncSearchQuery(query)
        guard !searchQuery.words.isEmpty else { return nodes }

        func filterNode(_ node: BookmarkTreeNode) -> BookmarkTreeNode? {
            guard node.isFolder else {
                return searchQuery.matches(title: node.title, url: node.url ?? "") ? node : nil
            }
            let matchedChildren = (node.children ?? []).compactMap(filterNode)
            if matchedChildren.isEmpty {
                return searchQuery.matches(title: node.title, url: "") ? node : nil
            }
            var narrowed = node
            narrowed.children = matchedChildren
            narrowed.totalCount = matchedChildren.reduce(0) { $0 + $1.totalCount }
            return narrowed
        }

        return nodes.compactMap(filterNode)
    }

    public static func collectAllFolderIDs(from nodes: [BookmarkTreeNode]) -> Set<String> {
        var ids = Set<String>()
        for node in nodes {
            if node.isFolder {
                ids.insert(node.id)
                if let children = node.children {
                    ids.formUnion(collectAllFolderIDs(from: children))
                }
            }
        }
        return ids
    }

    /// Every bookmark leaf under a folder node, recursively. A folder's
    /// swipe-to-delete/move acts on its whole subtree — the tree carries no
    /// folder-level command, so each leaf becomes its own per-bookmark command.
    public static func collectLeaves(from node: BookmarkTreeNode) -> [BookmarkTreeNode] {
        if !node.isFolder {
            return [node]
        }
        return (node.children ?? []).flatMap { collectLeaves(from: $0) }
    }

    /// A folder's path components, decoded from its tree id
    /// (`folder_Work/Projects` -> `["Work", "Projects"]`). Folders are built
    /// from `splitPath` components — which can never contain `/` — so this
    /// decode is unambiguous. Only *real* folders produced from a synced
    /// `folderPath` have a path that prefixes their own leaves; the synthetic
    /// "Other Bookmarks" aggregate (`folder_$synthetic/unfiled`) does not,
    /// which is how callers tell the two apart.
    public static func folderPathComponents(of node: BookmarkTreeNode) -> [String] {
        let prefix = "folder_"
        guard node.isFolder, node.id.hasPrefix(prefix) else { return [] }
        return String(node.id.dropFirst(prefix.count))
            .split(separator: "/")
            .map(String.init)
    }
}

/// One `deleteBookmarkFolder` command: the folder at `folderPath` in one
/// browser profile on one Mac. A merged phone folder can span several
/// profiles/Macs, so a folder delete is one request per source.
public struct FolderDeleteRequest: Equatable, Sendable {
    public let source: BookmarkSource
    public let folderPath: [String]
    /// The synced bookmark ids inside, hidden while the request travels.
    public let bookmarkIDs: [String]
}

public enum FolderDeletePlan: Equatable, Sendable {
    case send([FolderDeleteRequest])
    /// A target Mac runs a FastTab too old to understand the command; it
    /// would drop it silently, so nothing is sent.
    case macNeedsUpdate(macName: String)
    case notDeletable(reason: String)
}

public enum FolderDeletePlanner {
    public static let safariReason = "Safari bookmarks can't be changed from FastTab"
    public static let rootReason = "Built-in bookmark folders can't be deleted"
    public static let syntheticReason = "This group isn't a real folder on your Mac"

    public static func isSafari(_ browserName: String) -> Bool {
        browserName.lowercased().contains("safari")
    }

    /// Every subfolder at any depth below `node`.
    public static func subfolderCount(of node: BookmarkTreeNode) -> Int {
        (node.children ?? []).reduce(0) { $1.isFolder ? $0 + 1 + subfolderCount(of: $1) : $0 }
    }

    /// Why `node` can't be deleted as a folder, or nil when it can.
    public static func blockReason(for node: BookmarkTreeNode) -> String? {
        guard node.isFolder else { return syntheticReason }
        if node.id.contains("$synthetic") { return syntheticReason }
        let path = BookmarkTreeBuilder.folderPathComponents(of: node)
        if path.isEmpty { return syntheticReason }
        if path.count == 1 { return rootReason }
        let leaves = BookmarkTreeBuilder.collectLeaves(from: node)
        if leaves.contains(where: { isSafari($0.source?.browserName ?? "") }) { return safariReason }
        return nil
    }

    /// `devices` are the Macs the phone knows (their records carry capabilities).
    public static func plan(for node: BookmarkTreeNode, devices: [SyncedDevice]) -> FolderDeletePlan {
        if let reason = blockReason(for: node) { return .notDeletable(reason: reason) }
        let path = BookmarkTreeBuilder.folderPathComponents(of: node)
        var order: [String] = []
        var bySource: [String: (source: BookmarkSource, ids: [String])] = [:]
        for leaf in BookmarkTreeBuilder.collectLeaves(from: node) {
            guard let source = leaf.source, let item = leaf.bookmarkItem else { continue }
            if bySource[source.blobID] == nil {
                order.append(source.blobID)
                bySource[source.blobID] = (source, [])
            }
            bySource[source.blobID]?.ids.append(item.id)
        }
        guard !order.isEmpty else { return .notDeletable(reason: syntheticReason) }
        for blobID in order {
            guard let source = bySource[blobID]?.source else { continue }
            let device = devices.first { $0.id == source.deviceID }
            if !(device?.supports(SyncedDeviceCapability.deleteBookmarkFolder) ?? false) {
                return .macNeedsUpdate(macName: device?.name ?? "your Mac")
            }
        }
        return .send(order.compactMap { blobID in
            bySource[blobID].map { FolderDeleteRequest(source: $0.source, folderPath: path, bookmarkIDs: $0.ids) }
        })
    }

    /// `Delete folder "X" and its N bookmarks (incl. M subfolders)? This can't be undone.`
    public static func confirmation(folderName: String, bookmarkCount: Int, subfolderCount: Int) -> String {
        let bookmarks = bookmarkCount == 1 ? "1 bookmark" : "\(bookmarkCount) bookmarks"
        let subfolders: String
        switch subfolderCount {
        case 0: subfolders = ""
        case 1: subfolders = " (incl. 1 subfolder)"
        default: subfolders = " (incl. \(subfolderCount) subfolders)"
        }
        return "Delete folder \"\(folderName)\" and its \(bookmarks)\(subfolders)? This can't be undone."
    }
}
