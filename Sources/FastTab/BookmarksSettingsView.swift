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

    private var rows: [BookmarkDisplayRow] {
        let all = bookmarkTreeStore.flattenedRows(liveTabs: appState.browserService.cachedLiveTabs)
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        let folded = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return all.filter { row in
            guard case .bookmark(let item, _, _, _, _) = row else { return false }
            return item.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(folded)
                || item.url.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).contains(folded)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter bookmarks", text: $filterText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(12)

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
