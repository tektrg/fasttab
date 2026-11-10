import Foundation
import FastTabSync

/// Which folder to delete. The Mac UI knows the browser's own folder id; the
/// phone only knows display-name paths (its synced bookmarks carry no folder
/// ids), so both locators exist.
enum BookmarkFolderLocator: Equatable, Sendable {
    /// The browser's raw folder id (Chromium `Bookmarks` JSON `id`).
    case id(String)
    /// Full display-name trail from the root folder, e.g. `["Bookmarks Bar", "Work"]`.
    case path([String])
}

struct BookmarkFolderTarget: Equatable, Sendable {
    let profileName: String
    let locator: BookmarkFolderLocator
}

/// The result of a whole-folder delete. Every non-`deleted` case leaves the
/// bookmarks exactly as they were.
enum BookmarkFolderDeleteOutcome: Equatable, Sendable {
    case deleted(bookmarkCount: Int, subfolderCount: Int)
    case notFound
    /// Bookmark bar / Other / Mobile (synced) — never deletable.
    case rootFolder
    /// The path matches more than one folder; deleting either could be wrong.
    case ambiguous
    /// The browser's bookmarks can't be written by FastTab (Safari).
    case readOnlyBrowser
    case failed
}

/// A folder found in the bookmark file, before anything is removed.
struct LocatedBookmarkFolder: Equatable, Sendable {
    let id: String
    let title: String
    /// Display names from the root folder down to (excluding) this folder.
    let ancestorTitles: [String]
    let bookmarkCount: Int
    let subfolderCount: Int
}

enum BookmarkFolderLocateResult: Equatable, Sendable {
    case found(LocatedBookmarkFolder)
    case failed(BookmarkFolderDeleteOutcome)
}

/// User-facing copy shared by the Mac UI and the phone's sync answer.
enum BookmarkFolderDeleteCopy {
    static let safariReadOnly = "Safari bookmarks can't be changed from FastTab"
    static let readOnlyBrowser = "This browser's bookmarks can't be changed from FastTab"

    static func isSafari(_ browserName: String) -> Bool {
        browserName.localizedCaseInsensitiveContains("Safari")
    }

    static func readOnlyReason(browserName: String) -> String {
        isSafari(browserName) ? safariReadOnly : readOnlyBrowser
    }

    /// `Delete folder "X" and its N bookmarks (incl. M subfolders)? This can't be undone.`
    static func confirmation(folderName: String, bookmarkCount: Int, subfolderCount: Int) -> String {
        let bookmarks = bookmarkCount == 1 ? "1 bookmark" : "\(bookmarkCount) bookmarks"
        let subfolders: String
        switch subfolderCount {
        case 0: subfolders = ""
        case 1: subfolders = " (incl. 1 subfolder)"
        default: subfolders = " (incl. \(subfolderCount) subfolders)"
        }
        return "Delete folder \"\(folderName)\" and its \(bookmarks)\(subfolders)? This can't be undone."
    }

    /// What the phone sees for a finished `deleteBookmarkFolder` command.
    static func syncResponse(for outcome: BookmarkFolderDeleteOutcome, browserName: String) -> (status: SyncCommandStatus, reason: String) {
        switch outcome {
        case .deleted(let bookmarks, _):
            return (.done, "Folder deleted on Mac (\(bookmarks == 1 ? "1 bookmark" : "\(bookmarks) bookmarks"))")
        case .notFound:
            return (.notFound, "Folder not found on your Mac")
        case .rootFolder:
            return (.refused, "Built-in bookmark folders can't be deleted")
        case .ambiguous:
            return (.refused, "More than one folder has this name — delete it from FastTab on your Mac")
        case .readOnlyBrowser:
            return (.refused, readOnlyReason(browserName: browserName))
        case .failed:
            return (.refused, "Couldn't delete the folder on your Mac")
        }
    }
}

/// Whether a folder row in the Mac bookmark tree offers Delete.
enum BookmarkFolderDeleteAvailability: Equatable, Sendable {
    /// No action at all (root folders).
    case hidden
    /// Shown but disabled, with the reason as help text.
    case disabled(reason: String)
    case allowed

    static func of(_ folder: BookmarkFolder) -> BookmarkFolderDeleteAvailability {
        if BookmarkFolderDeleteCopy.isSafari(folder.browserName) {
            return .disabled(reason: BookmarkFolderDeleteCopy.safariReadOnly)
        }
        if folder.isSynthesized { return .disabled(reason: BookmarkFolderDeleteCopy.readOnlyBrowser) }
        if folder.isRoot { return .hidden }
        return .allowed
    }
}

/// Pure edits on a Chromium `Bookmarks` JSON `roots` dictionary.
enum ChromiumBookmarkFolderEditor {
    private struct Match {
        let rootKey: String
        /// Child indexes from the root node down to the folder.
        let indexPath: [Int]
        let node: [String: Any]
        let ancestorTitles: [String]
    }

    static func locate(_ locator: BookmarkFolderLocator, in roots: [String: Any]) -> BookmarkFolderLocateResult {
        switch findMatches(locator, in: roots) {
        case .failure(let outcome):
            return .failed(outcome)
        case .success(let match):
            let counts = countContents(of: match.node)
            return .found(LocatedBookmarkFolder(
                id: (match.node["id"] as? String) ?? "",
                title: (match.node["name"] as? String) ?? "",
                ancestorTitles: match.ancestorTitles,
                bookmarkCount: counts.bookmarks,
                subfolderCount: counts.folders
            ))
        }
    }

    /// Removes the folder and its whole subtree. `roots` is untouched unless
    /// the result is `.deleted`.
    static func remove(_ locator: BookmarkFolderLocator, from roots: inout [String: Any]) -> BookmarkFolderDeleteOutcome {
        switch findMatches(locator, in: roots) {
        case .failure(let outcome):
            return outcome
        case .success(let match):
            guard var rootNode = roots[match.rootKey] as? [String: Any],
                  removeChild(at: match.indexPath, from: &rootNode) else { return .failed }
            let counts = countContents(of: match.node)
            roots[match.rootKey] = rootNode
            return .deleted(bookmarkCount: counts.bookmarks, subfolderCount: counts.folders)
        }
    }

    private enum FindResult {
        case success(Match)
        case failure(BookmarkFolderDeleteOutcome)
    }

    private static func isFolder(_ node: [String: Any]) -> Bool {
        (node["type"] as? String) == "folder" || (node["type"] == nil && node["children"] != nil)
    }

    private static func findMatches(_ locator: BookmarkFolderLocator, in roots: [String: Any]) -> FindResult {
        let rootNodes = roots.compactMap { key, value -> (String, [String: Any])? in
            guard let node = value as? [String: Any] else { return nil }
            return (key, node)
        }.sorted { $0.0 < $1.0 }

        var matches: [Match] = []
        switch locator {
        case .id(let id):
            guard !id.isEmpty else { return .failure(.notFound) }
            if rootNodes.contains(where: { ($0.1["id"] as? String) == id }) { return .failure(.rootFolder) }
            for (key, node) in rootNodes {
                let rootName = (node["name"] as? String) ?? key
                walk(node, rootKey: key, indexPath: [], trail: [rootName]) { child, path, trail in
                    if (child["id"] as? String) == id {
                        if isFolder(child) {
                            matches.append(Match(rootKey: key, indexPath: path, node: child, ancestorTitles: Array(trail.dropLast())))
                        }
                        return false
                    }
                    return true
                }
            }
        case .path(let path):
            guard let first = path.first else { return .failure(.notFound) }
            let rootHits = rootNodes.filter { key, node in
                let name = (node["name"] as? String) ?? key.replacingOccurrences(of: "_", with: " ").capitalized
                return name == first
            }
            guard !rootHits.isEmpty else { return .failure(.notFound) }
            if path.count == 1 { return .failure(.rootFolder) }
            for (key, node) in rootHits {
                collectPathMatches(node, remaining: Array(path.dropFirst()), rootKey: key, indexPath: [], trail: [first], into: &matches)
            }
        }

        if matches.isEmpty { return .failure(.notFound) }
        if matches.count > 1 { return .failure(.ambiguous) }
        return .success(matches[0])
    }

    /// Depth-first over folder children. `visit` returns whether to descend.
    private static func walk(
        _ node: [String: Any],
        rootKey: String,
        indexPath: [Int],
        trail: [String],
        visit: ([String: Any], [Int], [String]) -> Bool
    ) {
        guard let children = node["children"] as? [[String: Any]] else { return }
        for (index, child) in children.enumerated() {
            let path = indexPath + [index]
            let childTrail = trail + [(child["name"] as? String) ?? ""]
            if visit(child, path, childTrail), isFolder(child) {
                walk(child, rootKey: rootKey, indexPath: path, trail: childTrail, visit: visit)
            }
        }
    }

    private static func collectPathMatches(
        _ node: [String: Any],
        remaining: [String],
        rootKey: String,
        indexPath: [Int],
        trail: [String],
        into matches: inout [Match]
    ) {
        guard let name = remaining.first, let children = node["children"] as? [[String: Any]] else { return }
        for (index, child) in children.enumerated() where isFolder(child) && (child["name"] as? String) == name {
            let path = indexPath + [index]
            if remaining.count == 1 {
                matches.append(Match(rootKey: rootKey, indexPath: path, node: child, ancestorTitles: trail))
            } else {
                collectPathMatches(child, remaining: Array(remaining.dropFirst()), rootKey: rootKey, indexPath: path, trail: trail + [name], into: &matches)
            }
        }
    }

    private static func removeChild(at indexPath: [Int], from node: inout [String: Any]) -> Bool {
        guard let index = indexPath.first, var children = node["children"] as? [[String: Any]], children.indices.contains(index) else {
            return false
        }
        if indexPath.count == 1 {
            children.remove(at: index)
        } else {
            var child = children[index]
            guard removeChild(at: Array(indexPath.dropFirst()), from: &child) else { return false }
            children[index] = child
        }
        node["children"] = children
        return true
    }

    static func countContents(of node: [String: Any]) -> (bookmarks: Int, folders: Int) {
        var bookmarks = 0
        var folders = 0
        for child in (node["children"] as? [[String: Any]]) ?? [] {
            if isFolder(child) {
                folders += 1
                let inner = countContents(of: child)
                bookmarks += inner.bookmarks
                folders += inner.folders
            } else if (child["type"] as? String) == "url" {
                bookmarks += 1
            }
        }
        return (bookmarks, folders)
    }
}
