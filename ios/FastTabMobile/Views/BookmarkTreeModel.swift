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
                bookmarks.append((source, bookmark))
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
                if rawPath.isEmpty {
                    unfiledItems.append((source, bm))
                } else {
                    let components = splitPath(rawPath)
                    if components.isEmpty {
                        unfiledItems.append((source, bm))
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
