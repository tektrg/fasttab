import SwiftUI
import FastTabSync

public struct BookmarkTreeNode: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: String?
    public let browserName: String?
    public let isFolder: Bool
    public var children: [BookmarkTreeNode]?
    public var bookmarkItem: SyncedBookmarkItem?
    public var totalCount: Int

    public init(
        id: String,
        title: String,
        url: String? = nil,
        browserName: String? = nil,
        isFolder: Bool,
        children: [BookmarkTreeNode]? = nil,
        bookmarkItem: SyncedBookmarkItem? = nil,
        totalCount: Int = 1
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.browserName = browserName
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
        var bookmarks: [SyncedBookmarkItem] = []

        init(name: String) {
            self.name = name
        }

        func insert(pathComponents: [String], bookmark: SyncedBookmarkItem) {
            if pathComponents.isEmpty {
                bookmarks.append(bookmark)
            } else {
                let first = pathComponents[0]
                let rest = Array(pathComponents.dropFirst())
                let sub = subfolders[first] ?? MutableFolderNode(name: first)
                subfolders[first] = sub
                sub.insert(pathComponents: rest, bookmark: bookmark)
            }
        }

        func toTreeNode(idPrefix: String = "") -> BookmarkTreeNode {
            let currentID = idPrefix.isEmpty ? name : "\(idPrefix)/\(name)"

            let sortedFolderKeys = subfolders.keys.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            let folderChildren = sortedFolderKeys.compactMap { subfolders[$0]?.toTreeNode(idPrefix: currentID) }

            let bookmarkChildren = bookmarks.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }.map { bm in
                BookmarkTreeNode(
                    id: "bm_\(bm.id)",
                    title: bm.title.isEmpty ? bm.url : bm.title,
                    url: bm.url,
                    browserName: nil,
                    isFolder: false,
                    children: nil,
                    bookmarkItem: bm,
                    totalCount: 1
                )
            }

            let allChildren = folderChildren + bookmarkChildren
            let count = allChildren.reduce(0) { $0 + $1.totalCount }

            return BookmarkTreeNode(
                id: "folder_\(currentID)",
                title: name,
                url: nil,
                browserName: nil,
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
        var unfiledItems: [SyncedBookmarkItem] = []

        for blob in blobs {
            for bm in blob.bookmarks {
                let rawPath = bm.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if rawPath.isEmpty {
                    unfiledItems.append(bm)
                } else {
                    let components = splitPath(rawPath)
                    if components.isEmpty {
                        unfiledItems.append(bm)
                    } else {
                        root.insert(pathComponents: components, bookmark: bm)
                    }
                }
            }
        }

        let sortedFolderKeys = root.subfolders.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        var topNodes = sortedFolderKeys.compactMap { root.subfolders[$0]?.toTreeNode() }

        if !root.bookmarks.isEmpty {
            let rootBms = root.bookmarks.map { bm in
                BookmarkTreeNode(
                    id: "bm_\(bm.id)",
                    title: bm.title.isEmpty ? bm.url : bm.title,
                    url: bm.url,
                    isFolder: false,
                    totalCount: 1
                )
            }
            topNodes.append(contentsOf: rootBms)
        }

        if !unfiledItems.isEmpty {
            let unfiledNodes = unfiledItems.map { bm in
                BookmarkTreeNode(
                    id: "bm_\(bm.id)",
                    title: bm.title.isEmpty ? bm.url : bm.title,
                    url: bm.url,
                    browserName: nil,
                    isFolder: false,
                    children: nil,
                    bookmarkItem: bm,
                    totalCount: 1
                )
            }
            topNodes.append(BookmarkTreeNode(
                id: "folder_unfiled",
                title: "Other Bookmarks",
                url: nil,
                browserName: nil,
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
}

public struct BookmarkTreeView: View {
    @ObservedObject var localCache = LocalCache.shared
    public let device: SyncedDevice?

    @State private var filterText: String = ""
    @State private var selectedURLForReader: URL?
    @State private var expandedFolderIDs: Set<String> = []
    @State private var hasInitializedExpansion: Bool = false
    @State private var toastMessage: String?
    @State private var showToast: Bool = false

    public init(device: SyncedDevice?) {
        self.device = device
    }

    private var allBookmarkBlobs: [SyncedBookmarkBlob] {
        localCache.state.bookmarkBlobs.filter {
            if let device { return $0.deviceID == device.id }
            return true
        }
    }

    private var treeRootNodes: [BookmarkTreeNode] {
        BookmarkTreeBuilder.buildTree(from: allBookmarkBlobs)
    }

    private var filteredNodes: [BookmarkTreeNode] {
        let q = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return treeRootNodes }

        func filterNode(_ node: BookmarkTreeNode) -> BookmarkTreeNode? {
            if node.isFolder {
                let matchedChildren = (node.children ?? []).compactMap { filterNode($0) }
                if !matchedChildren.isEmpty || node.title.lowercased().contains(q) {
                    var copy = node
                    copy.children = matchedChildren.isEmpty ? node.children : matchedChildren
                    copy.totalCount = matchedChildren.isEmpty ? node.totalCount : matchedChildren.reduce(0) { $0 + $1.totalCount }
                    return copy
                }
                return nil
            } else {
                let matchesTitle = node.title.lowercased().contains(q)
                let matchesURL = (node.url ?? "").lowercased().contains(q)
                return (matchesTitle || matchesURL) ? node : nil
            }
        }

        return treeRootNodes.compactMap { filterNode($0) }
    }

    private var allFolderIDs: Set<String> {
        BookmarkTreeBuilder.collectAllFolderIDs(from: treeRootNodes)
    }

    public var body: some View {
        VStack(spacing: 0) {
            DataFreshnessBanner(device: device, lastSyncedAt: localCache.state.lastSyncedAt)

            if filteredNodes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(filterText.isEmpty ? "No Bookmarks Synced" : "No Bookmarks Match \"\(filterText)\"")
                        .font(.headline)
                    Text(filterText.isEmpty ? "Bookmarks from Safari, Chrome, and Edge will appear here." : "Check spelling or clear the search field.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredNodes) { node in
                        BookmarkNodeRow(
                            node: node,
                            expandedFolderIDs: $expandedFolderIDs,
                            onSelectBookmark: { url in
                                selectedURLForReader = url
                            },
                            onToast: { msg in
                                showToast(message: msg)
                            }
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await SyncConsumer.shared.refreshNow()
                }
            }
        }
        .searchable(text: $filterText, prompt: "Filter bookmarks...")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !allFolderIDs.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if expandedFolderIDs.isEmpty {
                                expandedFolderIDs = allFolderIDs
                            } else {
                                expandedFolderIDs.removeAll()
                            }
                        }
                    } label: {
                        Text(expandedFolderIDs.isEmpty ? "Expand All" : "Collapse All")
                            .font(.caption.weight(.medium))
                    }
                }
            }
        }
        .onAppear {
            if !hasInitializedExpansion && !treeRootNodes.isEmpty {
                // Expand top-level folders by default on open
                expandedFolderIDs = Set(treeRootNodes.filter(\.isFolder).map(\.id))
                hasInitializedExpansion = true
            }
        }
        .sheet(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if showToast, let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func showToast(message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
            showToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                showToast = false
            }
        }
    }
}

private struct BookmarkNodeRow: View {
    let node: BookmarkTreeNode
    @Binding var expandedFolderIDs: Set<String>
    let onSelectBookmark: (URL) -> Void
    let onToast: (String) -> Void

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expandedFolderIDs.contains(node.id) },
            set: { expand in
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expand {
                        expandedFolderIDs.insert(node.id)
                    } else {
                        expandedFolderIDs.remove(node.id)
                    }
                }
            }
        )
    }

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: isExpanded) {
                if let children = node.children {
                    ForEach(children) { child in
                        BookmarkNodeRow(
                            node: child,
                            expandedFolderIDs: $expandedFolderIDs,
                            onSelectBookmark: onSelectBookmark,
                            onToast: onToast
                        )
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 15))
                    Text(node.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(node.totalCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(Capsule())
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedFolderIDs.contains(node.id) {
                            expandedFolderIDs.remove(node.id)
                        } else {
                            expandedFolderIDs.insert(node.id)
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "bookmark")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.title)
                        .font(.body)
                        .lineLimit(1)
                    if let url = node.url {
                        Text(url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let urlStr = node.url, let url = URL(string: urlStr) {
                    onSelectBookmark(url)
                }
            }
            .contextMenu {
                if let urlStr = node.url, let url = URL(string: urlStr) {
                    Button {
                        onSelectBookmark(url)
                    } label: {
                        Label("Open in Reader", systemImage: "doc.plaintext")
                    }

                    Link(destination: url) {
                        Label("Open in Safari", systemImage: "safari")
                    }

                    Button {
                        UIPasteboard.general.string = urlStr
                        onToast("URL Copied")
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }

                    Button {
                        SyncConsumer.shared.sendOpenOnMac(url: urlStr, title: node.title)
                        onToast("Sent to Mac")
                    } label: {
                        Label("Open on Mac", systemImage: "laptopcomputer")
                    }
                }
            }
        }
    }
}
