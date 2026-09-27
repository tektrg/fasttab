import SwiftUI
import FastTabSync


public struct BookmarkTreeView: View {
    @ObservedObject var localCache = LocalCache.shared
    public let device: SyncedDevice?

    @State private var filterText: String = ""
    @State private var selectedURLForReader: URL?
    @State private var readerItem: ReaderNavigationItem?
    @State private var expandedFolderIDs: Set<String> = []
    @State private var hasInitializedExpansion: Bool = false
    @State private var toast: String?
    /// Bookmarks the user asked to delete or move, each tied to the command
    /// that carries the request — same shape as `TabListView`'s
    /// `pendingCloses` and for the same reason: the outcome is always read
    /// back live from `LocalCache`, never stored here, so a row only stays
    /// hidden while the action is genuinely still in flight or genuinely done.
    @State private var pendingActions: [PendingBookmarkAction] = []
    /// The row being moved — a single bookmark or a whole folder. A folder
    /// carries no `BookmarkSource` of its own, so the destination picker is
    /// scoped by the folder's leaves' shared device instead.
    @State private var moveRequest: MoveRequest?
    /// A folder awaiting delete confirmation. A swipe-to-delete on a folder
    /// removes every bookmark inside it at once, so unlike a single-bookmark
    /// delete it asks first.
    @State private var pendingDeleteFolder: BookmarkTreeNode?
    @State private var newFolderContext: TreeNewFolderContext?

    private struct TreeNewFolderContext: Identifiable {
        let id = UUID()
        var profileKey: String? = nil
        var parentPath: [String] = []
        var deviceID: String = ""
    }

    public init(device: SyncedDevice?) {
        self.device = device
    }

    /// Which move the destination picker was opened for. A bookmark lands
    /// directly in the picked destination; a folder nests itself under it,
    /// keeping its subfolder structure.
    private enum MoveRequest: Identifiable {
        case bookmark(BookmarkTreeNode)
        case folder(BookmarkTreeNode)

        var id: String {
            switch self {
            case .bookmark(let node), .folder(let node): return node.id
            }
        }

        var sourceDeviceID: String {
            switch self {
            case .bookmark(let node): return node.source?.deviceID ?? ""
            case .folder(let node):
                // The Move swipe only appears when every leaf shares one
                // device (`canMoveFolder`), so the first leaf's is the device's.
                return BookmarkTreeBuilder.collectLeaves(from: node).first?.source?.deviceID ?? ""
            }
        }

        /// Destinations that are the moved thing's current home, so the picker
        /// keeps them off the list — you can't "move" something to where it
        /// already is. A bookmark only excludes its own exact folder; a folder
        /// also excludes its subpaths and direct parent.
        var folderMoveExclusion: FolderMoveExclusion? {
            switch self {
            case .bookmark(let node):
                guard let source = node.source, let bookmark = node.bookmarkItem else { return nil }
                return FolderMoveExclusion(
                    path: BookmarkTreeBuilder.splitPath(bookmark.folderPath ?? ""),
                    profileKeys: ["\(source.browserName)|\(source.profileName)"],
                    includeSubpaths: false
                )
            case .folder(let node):
                let path = BookmarkTreeBuilder.folderPathComponents(of: node)
                let profileKeys = Set(BookmarkTreeBuilder.collectLeaves(from: node).compactMap { leaf -> String? in
                    guard let s = leaf.source else { return nil }
                    return "\(s.browserName)|\(s.profileName)"
                })
                return FolderMoveExclusion(path: path, profileKeys: profileKeys, includeSubpaths: true)
            }
        }
    }

    private var allBookmarkBlobs: [SyncedBookmarkBlob] {
        localCache.state.bookmarkBlobs.filter {
            if let device { return $0.deviceID == device.id }
            return true
        }
    }

    // MARK: - Delete/move requests in flight

    private func progress(for pending: PendingBookmarkAction) -> CommandProgress? {
        guard let command = localCache.state.sentCommands.first(where: { $0.id == pending.commandID }) else {
            return nil
        }
        return CommandProgress.of(
            command: command,
            delivery: localCache.delivery(forCommandID: pending.commandID)
        )
    }

    private var trackedActions: [TrackedBookmarkAction] {
        pendingActions.compactMap { pending in
            guard let progress = progress(for: pending) else { return nil }
            return TrackedBookmarkAction(action: pending, progress: progress)
        }
    }

    /// A row disappears only while its delete/move is still travelling or has
    /// actually happened. A failure puts it straight back, because the
    /// bookmark is still there on the Mac. Keyed by `PendingBookmarkAction
    /// .hideKey` (blob id + bookmark id), never the bare bookmark id — see
    /// `BookmarkSource.blobID`. Delete and move share this hidden set: either
    /// one hides the same underlying row while in flight.
    private var hiddenBookmarkIDs: Set<String> {
        Set(trackedActions.filter { !$0.progress.isFailure }.map(\.action.hideKey))
    }

    /// Every synced bookmark's current identity (`blobID#bookmarkID`). A
    /// successful move relocates a bookmark into another blob *without changing
    /// the total count*, so the old count-based prune trigger missed finished
    /// moves and their actions lingered invisibly; pruning off identity instead
    /// fires on both deletes and moves.
    private var liveBookmarkIdentity: Set<String> {
        Set(localCache.state.bookmarkBlobs.flatMap { blob in
            blob.bookmarks.map { "\(blob.id)#\($0.id)" }
        })
    }

    /// Drops requests nothing can display any more: the Mac confirmed the
    /// delete/move and the bookmark has since left the synced list under its
    /// old blob+id, or the command itself is gone. This check is identical
    /// for both kinds — a successful move removes the same (blobID,
    /// bookmarkID) pair from its original blob that a successful delete does.
    private func pruneFinishedActions() {
        let live = liveBookmarkIdentity
        pendingActions.removeAll { pending in
            guard let progress = progress(for: pending) else { return true }
            return progress.stage == .succeeded && !live.contains(pending.hideKey)
        }
    }

    private var visibleBookmarkBlobs: [SyncedBookmarkBlob] {
        let hiddenIDs = hiddenBookmarkIDs
        guard !hiddenIDs.isEmpty else { return allBookmarkBlobs }
        return allBookmarkBlobs.map { blob in
            SyncedBookmarkBlob(
                id: blob.id,
                deviceID: blob.deviceID,
                browserName: blob.browserName,
                profileName: blob.profileName,
                contentHash: blob.contentHash,
                updatedAt: blob.updatedAt,
                bookmarks: blob.bookmarks.filter { !hiddenIDs.contains("\(blob.id)#\($0.id)") }
            )
        }
    }

    private var treeRootNodes: [BookmarkTreeNode] {
        BookmarkTreeBuilder.buildTree(from: visibleBookmarkBlobs)
    }

    private var filteredNodes: [BookmarkTreeNode] {
        BookmarkTreeBuilder.filter(treeRootNodes, matching: filterText)
    }

    private var allFolderIDs: Set<String> {
        BookmarkTreeBuilder.collectAllFolderIDs(from: treeRootNodes)
    }

    /// A visible row in the flattened tree list: every folder header and
    /// bookmark leaf currently shown given the expansion state, in tree order,
    /// with a depth for indentation. Folders and bookmarks are separate `List`
    /// rows — no `DisclosureGroup` — because swipe actions attached to a
    /// `DisclosureGroup` container leak onto its expanded child rows (SwiftUI
    /// accumulates swipe actions per edge), which rendered duplicate Delete /
    /// Move buttons on nested bookmarks.
    private struct FlatBookmarkRow: Identifiable {
        let node: BookmarkTreeNode
        let depth: Int
        var id: String { node.id }
    }

    private var visibleRows: [FlatBookmarkRow] {
        func flatten(_ nodes: [BookmarkTreeNode], depth: Int) -> [FlatBookmarkRow] {
            var rows: [FlatBookmarkRow] = []
            for node in nodes {
                rows.append(FlatBookmarkRow(node: node, depth: depth))
                if node.isFolder, expandedFolderIDs.contains(node.id), let children = node.children {
                    rows.append(contentsOf: flatten(children, depth: depth + 1))
                }
            }
            return rows
        }
        return flatten(filteredNodes, depth: 0)
    }

    public var body: some View {
        VStack(spacing: 0) {
            PendingBookmarkActionStrip(tracked: trackedActions) { action in
                pendingActions.removeAll { $0.id == action.id }
            }
            .animation(.easeInOut(duration: 0.2), value: trackedActions)

            if filteredNodes.isEmpty {
                DSEmptyState(
                    filterText.isEmpty ? "No Bookmarks Synced" : "No Bookmarks Match \"\(filterText)\"",
                    systemImage: "bookmark.slash",
                    message: filterText.isEmpty ? "Bookmarks from Safari, Chrome, and Edge will appear here." : "Check spelling or clear the search field.",
                    style: .fullScreen
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleRows) { row in
                        BookmarkNodeRow(
                            node: row.node,
                            depth: row.depth,
                            isExpanded: expandedFolderIDs.contains(row.node.id),
                            onToggleExpand: { node in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if expandedFolderIDs.contains(node.id) {
                                        expandedFolderIDs.remove(node.id)
                                    } else {
                                        expandedFolderIDs.insert(node.id)
                                    }
                                }
                            },
                            onSelectBookmark: { url in
                                selectedURLForReader = url
                            },
                            onOpenInReader: { url, title in
                                readerItem = ReaderNavigationItem(url: url, title: title)
                            },
                            onToast: { msg in
                                showToast(message: msg)
                            },
                            onDelete: { node in
                                requestDelete(of: node)
                            },
                            onMove: { node in
                                moveRequest = .bookmark(node)
                            },
                            onDeleteFolder: { node in
                                pendingDeleteFolder = node
                            },
                            onMoveFolder: { node in
                                moveRequest = .folder(node)
                            },
                            onNewSubfolder: { node in
                                let path = BookmarkTreeBuilder.folderPathComponents(of: node)
                                let leaves = BookmarkTreeBuilder.collectLeaves(from: node)
                                let leafSource = leaves.first?.source
                                let devID = leafSource?.deviceID ?? device?.id ?? localCache.state.devices.first?.id ?? ""
                                let profKey = leafSource.map { "\($0.browserName)|\($0.profileName)" }
                                newFolderContext = TreeNewFolderContext(profileKey: profKey, parentPath: path, deviceID: devID)
                            }
                        )
                    }
                    .dsListRow()
                }
                .listStyle(.insetGrouped)
                .dsListStyle()
                .refreshable {
                    await SyncConsumer.shared.refreshNow()
                }
            }
        }
        .dsCanvas()
        .searchable(text: $filterText, prompt: "Filter bookmarks...")
        .onChange(of: liveBookmarkIdentity) {
            pruneFinishedActions()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: DS.Space.md) {
                    Button {
                        let targetDevID = device?.id ?? localCache.state.devices.first?.id ?? ""
                        newFolderContext = TreeNewFolderContext(deviceID: targetDevID)
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }

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
                                .font(DS.Font.meta.weight(.medium))
                        }
                    }
                }
            }
        }
        .sheet(item: $newFolderContext) { context in
            NewBookmarkFolderSheet(
                sourceDeviceID: context.deviceID,
                initialProfileKey: context.profileKey,
                initialParentPath: context.parentPath
            ) { browserName, profileName, folderName, parentFolderPath in
                let fullPath = parentFolderPath + [folderName]
                LocalCache.shared.registerCreatedFolder(
                    browserName: browserName,
                    profileName: profileName,
                    folderPath: fullPath,
                    deviceID: context.deviceID
                )
                SyncConsumer.shared.sendCreateFolder(
                    name: folderName,
                    parentFolderPath: parentFolderPath,
                    browserName: browserName,
                    profileName: profileName,
                    targetDeviceID: context.deviceID
                )
                // Expand parent folder and new folder so it becomes visible
                let newFolderID = "folder_\(fullPath.joined(separator: "/"))"
                expandedFolderIDs.insert(newFolderID)
                if !parentFolderPath.isEmpty {
                    let parentID = "folder_\(parentFolderPath.joined(separator: "/"))"
                    expandedFolderIDs.insert(parentID)
                }
                showToast(message: "Created folder '\(folderName)'")
            }
        }
        .onAppear {
            if !hasInitializedExpansion && !treeRootNodes.isEmpty {
                // Expand top-level folders by default on open
                expandedFolderIDs = Set(treeRootNodes.filter(\.isFolder).map(\.id))
                hasInitializedExpansion = true
            }
        }
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
        }
        .sheet(item: $moveRequest) { request in
            BookmarkMovePicker(
                sourceDeviceID: request.sourceDeviceID,
                folderMoveExclusion: request.folderMoveExclusion
            ) { destination in
                switch request {
                case .bookmark(let node):
                    requestMove(of: node, to: destination)
                case .folder(let node):
                    requestMoveFolder(of: node, to: destination)
                }
            }
        }
        .confirmationDialog(
            "Delete Folder?",
            isPresented: Binding(
                get: { pendingDeleteFolder != nil },
                set: { if !$0 { pendingDeleteFolder = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeleteFolder
        ) { node in
            Button("Delete Folder", role: .destructive) {
                confirmDeleteFolder(node)
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteFolder = nil
            }
        } message: { node in
            // A merged folder can span Macs; delete goes to every one, so the
            // confirmation's blast radius should name them correctly.
            let macCount = Set(BookmarkTreeBuilder.collectLeaves(from: node).compactMap { $0.source?.deviceID }).count
            Text("Delete \"\(node.title)\" and its \(node.totalCount) bookmark\(node.totalCount == 1 ? "" : "s") from your \(macCount > 1 ? "Macs" : "Mac")?")
        }
        .dsToast($toast, bottomInset: DS.Space.xl)
    }

    private func showToast(message: String) {
        toast = message
    }

    /// Asks the owning Mac to delete a bookmark, and hides the row only for as
    /// long as that request is genuinely travelling or genuinely done. Mirrors
    /// `TabListView.requestClose(of:)` — see that comment for why the command id
    /// has to be recovered by diffing `sentCommands` rather than returned directly.
    private func requestDelete(of node: BookmarkTreeNode) {
        guard issueDeleteCommand(for: node) != nil else {
            showToast(message: "Couldn't queue that delete — the bookmark is still there")
            return
        }
        showToast(message: actionAcknowledgement(for: node.source?.deviceID ?? "", verb: "Delete"))
    }

    /// Asks the owning Mac to move a bookmark into a different profile/folder
    /// on that same Mac. Mirrors `requestDelete(of:)` above.
    private func requestMove(of node: BookmarkTreeNode, to destination: BookmarkMoveDestination) {
        guard issueMoveCommand(for: node, to: destination) != nil else {
            showToast(message: "Couldn't queue that move — the bookmark hasn't moved")
            return
        }
        showToast(message: actionAcknowledgement(for: node.source?.deviceID ?? "", verb: "Move"))
    }

    /// Sends a delete command for one bookmark and tracks it as a pending
    /// action. Returns `nil` when the row has no commandable source or the
    /// command never surfaced in `sentCommands` (so the caller can't claim a
    /// queue that didn't happen). Shared by single-bookmark and whole-folder
    /// deletes — a folder delete is just this, once per leaf.
    @discardableResult
    private func issueDeleteCommand(for node: BookmarkTreeNode) -> PendingBookmarkAction? {
        guard let bookmark = node.bookmarkItem, let source = node.source else { return nil }

        let knownCommandIDs = Set(localCache.state.sentCommands.map(\.id))
        SyncConsumer.shared.sendDeleteBookmark(
            bookmark: bookmark,
            browserName: source.browserName,
            profileName: source.profileName,
            targetDeviceID: source.deviceID
        )

        guard let issued = localCache.state.sentCommands.first(where: { !knownCommandIDs.contains($0.id) }) else {
            return nil
        }

        let action = PendingBookmarkAction(
            blobID: source.blobID,
            bookmarkID: bookmark.id,
            commandID: issued.id,
            bookmarkTitle: node.title,
            kind: .delete
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            pendingActions.removeAll { $0.blobID == source.blobID && $0.bookmarkID == bookmark.id && $0.kind == .delete }
            pendingActions.append(action)
        }
        return action
    }

    /// Sends a move command for one bookmark and tracks it as a pending
    /// action. Same shape as `issueDeleteCommand(for:)`; the folder-move path
    /// calls it once per leaf, each with that leaf's own nested destination.
    @discardableResult
    private func issueMoveCommand(for node: BookmarkTreeNode, to destination: BookmarkMoveDestination) -> PendingBookmarkAction? {
        guard let bookmark = node.bookmarkItem, let source = node.source else { return nil }

        let knownCommandIDs = Set(localCache.state.sentCommands.map(\.id))
        SyncConsumer.shared.sendMoveBookmark(
            bookmark: bookmark,
            sourceBrowserName: source.browserName,
            sourceProfileName: source.profileName,
            destinationBrowserName: destination.browserName,
            destinationProfileName: destination.profileName,
            destinationFolderPath: destination.folderPath,
            targetDeviceID: source.deviceID
        )

        guard let issued = localCache.state.sentCommands.first(where: { !knownCommandIDs.contains($0.id) }) else {
            return nil
        }

        let action = PendingBookmarkAction(
            blobID: source.blobID,
            bookmarkID: bookmark.id,
            commandID: issued.id,
            bookmarkTitle: node.title,
            kind: .move
        )
        withAnimation(.easeInOut(duration: 0.2)) {
            pendingActions.removeAll { $0.blobID == source.blobID && $0.bookmarkID == bookmark.id && $0.kind == .move }
            pendingActions.append(action)
        }
        return action
    }

    /// Swipe-to-delete on a folder: asks for confirmation first (the dialog
    /// is driven by `pendingDeleteFolder`), then deletes every bookmark inside
    /// it — one command per leaf, each aimed at that leaf's own Mac.
    private func confirmDeleteFolder(_ node: BookmarkTreeNode) {
        let leaves = BookmarkTreeBuilder.collectLeaves(from: node)
        var issued = 0
        for leaf in leaves {
            if issueDeleteCommand(for: leaf) != nil { issued += 1 }
        }
        if issued == 0 {
            showToast(message: "Couldn't queue that delete — the folder is still there")
        } else {
            showToast(message: folderActionAcknowledgement(node: node, leaves: leaves, verb: "Delete"))
        }
    }

    /// Swipe-to-move on a folder: nests the folder (and everything inside it)
    /// under the picked destination. Each leaf moves to
    /// `destination + [folder name] + (its original subpath beyond the folder)`
    /// — so "Work/Projects" moved into "Archive" becomes "Archive/Work/Projects".
    private func requestMoveFolder(of node: BookmarkTreeNode, to destination: BookmarkMoveDestination) {
        let folderPath = BookmarkTreeBuilder.folderPathComponents(of: node)
        let leaves = BookmarkTreeBuilder.collectLeaves(from: node)

        // The picker already keeps the folder's current home off the list; this
        // guard catches the same case on a stale option. Scoped by profile — the
        // folder's path in a *different* profile is a legitimate destination, so
        // only a destination in a profile that actually holds the folder counts.
        let sourceProfileKeys = Set(leaves.compactMap { leaf -> String? in
            guard let s = leaf.source else { return nil }
            return "\(s.browserName)|\(s.profileName)"
        })
        let isSameHome = sourceProfileKeys.contains("\(destination.browserName)|\(destination.profileName)")
        let isCircular = isSameHome && (destination.folderPath == folderPath || destination.folderPath.starts(with: folderPath))
        // Moving a folder into its direct parent resolves to its current path —
        // a silent no-op that would still churn every leaf through the Mac.
        let isNoOp = isSameHome && destination.folderPath == Array(folderPath.dropLast())
        if isCircular || isNoOp {
            showToast(message: isCircular ? "Can't move '\(node.title)' into itself" : "'\(node.title)' is already in that folder")
            return
        }

        var issued = 0
        for leaf in leaves {
            guard let bookmark = leaf.bookmarkItem else { continue }
            let leafPath = BookmarkTreeBuilder.splitPath(bookmark.folderPath ?? "")
            let relativeSubpath = leafPath.starts(with: folderPath)
                ? Array(leafPath.dropFirst(folderPath.count))
                : []
            let nestedDestination = BookmarkMoveDestination(
                browserName: destination.browserName,
                profileName: destination.profileName,
                folderPath: destination.folderPath + [node.title] + relativeSubpath
            )
            if issueMoveCommand(for: leaf, to: nestedDestination) != nil { issued += 1 }
        }
        if issued == 0 {
            showToast(message: "Couldn't queue that move — the folder hasn't moved")
        } else {
            showToast(message: folderActionAcknowledgement(node: node, leaves: leaves, verb: "Move"))
        }
    }

    /// A folder action's acknowledgement names the folder and how many
    /// bookmarks it carries, and — because a merged folder can span Macs —
    /// names the Mac only when there's exactly one.
    private func folderActionAcknowledgement(node: BookmarkTreeNode, leaves: [BookmarkTreeNode], verb: String) -> String {
        let subject = leaves.count == 1 ? "1 bookmark" : "\(leaves.count) bookmarks"
        if SyncConsumer.shared.syncHealth.isBlocked {
            return "Saved on this iPhone — sync is off, so your Mac hasn't been told"
        }
        let targetDevices = Set(leaves.compactMap { $0.source?.deviceID })
        if targetDevices.count > 1 {
            return "\(verb) of '\(node.title)' queued for your Macs (\(subject))"
        }
        guard let deviceID = targetDevices.first else {
            return "\(verb) of '\(node.title)' queued for your Mac (\(subject))"
        }
        let deviceName = localCache.state.devices.first { $0.id == deviceID }?.name ?? "your Mac"
        return "\(verb) of '\(node.title)' queued for \(deviceName) (\(subject))"
    }

    /// The only thing that is true the instant the request is made: it is
    /// written down on this phone, and it has not reached the Mac yet.
    private func actionAcknowledgement(for deviceID: String, verb: String) -> String {
        if SyncConsumer.shared.syncHealth.isBlocked {
            return "Saved on this iPhone — sync is off, so your Mac hasn't been told"
        }
        let deviceName = localCache.state.devices.first { $0.id == deviceID }?.name ?? "your Mac"
        return "\(verb) queued for \(deviceName)"
    }
}
