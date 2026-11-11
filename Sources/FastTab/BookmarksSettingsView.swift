import SwiftUI

/// "Bookmarks" tab of Settings: the full browser bookmark tree that used to
/// live in the command bar's third tab. Folders expand/collapse, rows open
/// the bookmark (or focus its live tab), and bookmarks can be copied,
/// closed (when open), or deleted with a two-step confirm.
struct BookmarksSettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var bookmarkTreeStore = BookmarkTreeStore.shared

    @State private var filterText = ""
    @State private var errorMessage: String? = nil
    /// The folder awaiting the "Delete folder…?" confirmation.
    @State private var pendingFolderDelete: BookmarkFolder? = nil
    @State private var deletingFolderIDs: Set<String> = []

    private var rows: [BookmarkDisplayRow] {
        let all = bookmarkTreeStore.flattenedRows(liveTabs: appState.browserService.cachedLiveTabs)
        return BookmarkDisplayRow.filter(all, matching: filterText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        self.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            if rows.isEmpty {
                Spacer()
                Image(systemName: "bookmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(bookmarkTreeStore.rootFolders.isEmpty ? "No bookmarks found" : "No matches")
                    .font(.headline)
                    .padding(.top, 8)
                Text(bookmarkTreeStore.rootFolders.isEmpty
                    ? "Bookmarks from your enabled browsers will appear here."
                    : "Try another keyword.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            BookmarkTreeRow(
                                row: row,
                                isSelected: false,
                                onSelect: {
                                    switch row {
                                    case .folder(let id, _, _, _, _, _):
                                        bookmarkTreeStore.toggleFolder(id)
                                    case .bookmark(let item, _, let liveTab, _, _):
                                        if let liveTab {
                                            appState.browserService.activate(liveTab)
                                        } else {
                                            appState.browserService.activate(item.asSearchResult)
                                        }
                                    }
                                },
                                onToggleFolder: {
                                    if case .folder(let id, _, _, _, _, _) = row {
                                        bookmarkTreeStore.toggleFolder(id)
                                    }
                                },
                                onCopy: {
                                    if case .bookmark(let item, _, _, _, _) = row {
                                        appState.browserService.copyLinkToClipboard(item.asSearchResult)
                                    }
                                },
                                onRemove: {
                                    if case .bookmark(let item, _, _, let isArmed, let isDeleting) = row {
                                        guard !isDeleting else { return }
                                        if isArmed {
                                            deleteBookmarkConfirmed(item)
                                        } else {
                                            bookmarkTreeStore.armedBookmarkID = item.uniqueKey
                                        }
                                    }
                                },
                                onCloseTab: {
                                    if case .bookmark(_, _, let liveTab, _, _) = row, let liveTab {
                                        appState.browserService.remove(liveTab)
                                    }
                                },
                                folderDelete: folderDeleteAvailability(for: row),
                                onDeleteFolder: {
                                    if case .folder(let id, _, _, _, _, _) = row {
                                        pendingFolderDelete = bookmarkTreeStore.folder(withID: id)
                                    }
                                }
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            "Delete Folder?",
            isPresented: Binding(
                get: { pendingFolderDelete != nil },
                set: { if !$0 { pendingFolderDelete = nil } }
            ),
            presenting: pendingFolderDelete
        ) { folder in
            Button("Delete Folder", role: .destructive) {
                deleteFolderConfirmed(folder)
            }
            Button("Cancel", role: .cancel) {
                pendingFolderDelete = nil
            }
        } message: { folder in
            Text(BookmarkFolderDeleteCopy.confirmation(
                folderName: folder.name,
                bookmarkCount: folder.totalBookmarkCount,
                subfolderCount: folder.totalSubfolderCount
            ))
        }
    }

    private func folderDeleteAvailability(for row: BookmarkDisplayRow) -> BookmarkFolderDeleteAvailability {
        guard case .folder(let id, _, _, _, _, _) = row,
              !deletingFolderIDs.contains(id),
              let folder = bookmarkTreeStore.folder(withID: id) else { return .hidden }
        return BookmarkFolderDeleteAvailability.of(folder)
    }

    private func deleteFolderConfirmed(_ folder: BookmarkFolder) {
        pendingFolderDelete = nil
        deletingFolderIDs.insert(folder.id)
        errorMessage = nil
        Task {
            let outcome = await appState.browserService.deleteBookmarkFolderAsync(folder)
            await MainActor.run {
                deletingFolderIDs.remove(folder.id)
                switch outcome {
                case .deleted:
                    withAnimation(.easeOut(duration: 0.2)) {
                        _ = bookmarkTreeStore.removeFolder(id: folder.id)
                    }
                    appState.browserService.refreshBookmarkTreeAfterExternalChange()
                case .readOnlyBrowser:
                    errorMessage = BookmarkFolderDeleteCopy.readOnlyReason(browserName: folder.browserName)
                case .rootFolder:
                    errorMessage = "Built-in bookmark folders can't be deleted."
                case .notFound:
                    errorMessage = "\"\(folder.name)\" is no longer in \(folder.browserName)."
                    appState.browserService.refreshBookmarkTreeAfterExternalChange()
                case .ambiguous, .failed:
                    errorMessage = "Could not delete folder \"\(folder.name)\" from \(folder.browserName)."
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter bookmarks", text: $filterText)
                .textFieldStyle(.plain)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func deleteBookmarkConfirmed(_ item: BookmarkItem) {
        bookmarkTreeStore.armedBookmarkID = nil
        bookmarkTreeStore.deletingBookmarkIDs.insert(item.uniqueKey)
        errorMessage = nil
        Task {
            let ok = await appState.browserService.deleteBookmarkAsync(item.asSearchResult)
            await MainActor.run {
                if ok {
                    withAnimation(.easeOut(duration: 0.2)) {
                        _ = bookmarkTreeStore.removeBookmark(id: item.id, browserName: item.browserName, profileName: item.profileName)
                        bookmarkTreeStore.deletingBookmarkIDs.remove(item.uniqueKey)
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        bookmarkTreeStore.deletingBookmarkIDs.remove(item.uniqueKey)
                    }
                    errorMessage = "Could not delete bookmark from \(item.browserName)."
                }
            }
        }
    }
}
