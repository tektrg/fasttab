import SwiftUI
import FastTabSync

/// One row in the flattened bookmark tree — either a folder header or a
/// bookmark leaf. Folders and bookmarks share the same row shape and the same
/// swipe actions, so their Delete/Move buttons render identically. Each row
/// carries its own swipe actions exactly once: the tree is flattened in
/// `BookmarkTreeView` (no nested `DisclosureGroup`s) precisely because swipe
/// actions attached to a `DisclosureGroup` container leak onto its expanded
/// child rows, which made SwiftUI accumulate duplicate Delete/Move buttons on
/// nested bookmarks.
struct BookmarkNodeRow: View {
    let node: BookmarkTreeNode
    let depth: Int
    let isExpanded: Bool
    let onToggleExpand: (BookmarkTreeNode) -> Void
    let onSelectBookmark: (URL) -> Void
    let onToast: (String) -> Void
    let onDelete: (BookmarkTreeNode) -> Void
    let onMove: (BookmarkTreeNode) -> Void
    let onDeleteFolder: (BookmarkTreeNode) -> Void
    let onMoveFolder: (BookmarkTreeNode) -> Void

    /// Every bookmark leaf in this node's subtree — the rows a folder
    /// delete/move actually sends a command for, since the tree has no
    /// folder-level command (each leaf is one per-bookmark command).
    private var leafBookmarks: [BookmarkTreeNode] {
        BookmarkTreeBuilder.collectLeaves(from: node)
    }

    /// A folder is swipe-operable only when (a) it's a *real* folder, not the
    /// synthetic "Other Bookmarks" aggregate (which merges every source's
    /// unfiled bookmarks and has no folderPath of its own), and (b) every
    /// bookmark inside it is writable — Safari stays read-only everywhere, so
    /// a folder holding any Safari bookmark can't be fully deleted or moved.
    private var canOperateFolder: Bool {
        guard node.isFolder else { return false }
        let leaves = leafBookmarks
        guard !leaves.isEmpty else { return false }
        let path = BookmarkTreeBuilder.folderPathComponents(of: node)
        guard !path.isEmpty else { return false }
        guard leaves.contains(where: {
            BookmarkTreeBuilder.splitPath($0.bookmarkItem?.folderPath ?? "").starts(with: path)
        }) else { return false }
        return leaves.allSatisfy { !($0.source?.browserName.lowercased().contains("safari") ?? false) }
    }

    /// Move additionally needs every leaf on the *same* Mac: the destination
    /// picker scopes to one device, so a folder spanning several Macs can't
    /// move anywhere as a unit. Delete has no such restriction — each leaf
    /// goes to its own Mac.
    private var canMoveFolder: Bool {
        guard canOperateFolder else { return false }
        let leaves = leafBookmarks
        guard let firstDevice = leaves.first?.source?.deviceID else { return false }
        return leaves.allSatisfy { $0.source?.deviceID == firstDevice }
    }

    /// A bookmark leaf is only writable outside Safari (its backend silently
    /// refuses writes, so offering the swipe would look like it worked).
    private var isBookmarkWritable: Bool {
        !(node.source?.browserName.lowercased().contains("safari") ?? false)
    }

    private var canDelete: Bool {
        node.isFolder ? canOperateFolder : isBookmarkWritable
    }

    private var canMove: Bool {
        node.isFolder ? canMoveFolder : isBookmarkWritable
    }

    var body: some View {
        HStack(spacing: 8) {
            // Tree indentation: each level pushes the row content right by a
            // fixed step, in place of a DisclosureGroup's native indent.
            Color.clear
                .frame(width: CGFloat(depth) * 20)
                .frame(maxHeight: 1)

            if node.isFolder {
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
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
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
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isFolder {
                onToggleExpand(node)
            } else if let urlStr = node.url, let url = URL(string: urlStr) {
                onSelectBookmark(url)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // One shared Delete shape for folders and bookmarks, so the two
            // look identical. The folder variant still asks for confirmation
            // first (it removes a whole subtree); a bookmark deletes directly.
            if canDelete {
                Button(role: .destructive) {
                    if node.isFolder {
                        onDeleteFolder(node)
                    } else {
                        onDelete(node)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if canMove {
                Button {
                    if node.isFolder {
                        onMoveFolder(node)
                    } else {
                        onMove(node)
                    }
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            // Bookmark long-press menu only — folders get their actions from
            // the swipe, as before.
            if !node.isFolder, let urlStr = node.url, let url = URL(string: urlStr) {
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

                if isBookmarkWritable {
                    Divider()

                    Button {
                        onMove(node)
                    } label: {
                        Label("Move to Folder", systemImage: "folder")
                    }

                    Button(role: .destructive) {
                        onDelete(node)
                    } label: {
                        Label("Delete Bookmark", systemImage: "trash")
                    }
                }
            }
        }
    }
}
