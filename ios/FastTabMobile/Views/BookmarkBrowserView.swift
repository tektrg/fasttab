import SwiftUI
import FastTabSync

public struct BookmarkRowItem: Identifiable {
    public var id: String { "\(browser)|\(profile)|\(item.id)" }
    public let browser: String
    public let profile: String
    public let item: SyncedBookmarkItem
}

public struct BookmarkBrowserView: View {
    @ObservedObject var localCache = LocalCache.shared
    public let device: SyncedDevice?

    @State private var searchText: String = ""
    @State private var selectedFolder: String? = nil
    @State private var selectedURLForReader: URL?
    @State private var readerItem: ReaderNavigationItem?
    @State private var toast: String?

    public init(device: SyncedDevice?) {
        self.device = device
    }

    private var allBookmarks: [BookmarkRowItem] {
        let blobs = localCache.state.bookmarkBlobs.filter {
            if let device { return $0.deviceID == device.id }
            return true
        }

        var results: [BookmarkRowItem] = []
        for blob in blobs {
            for bm in blob.bookmarks {
                if !bm.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    results.append(BookmarkRowItem(browser: blob.browserName, profile: blob.profileName, item: bm))
                }
            }
        }
        return results
    }

    private var filteredBookmarks: [BookmarkRowItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            if let folder = selectedFolder {
                var matches: [BookmarkRowItem] = []
                for entry in allBookmarks {
                    if entry.item.folderPath == folder {
                        matches.append(entry)
                    }
                }
                return matches
            }
            return allBookmarks
        }
        var matches: [BookmarkRowItem] = []
        for entry in allBookmarks {
            if SyncSearchMatcher.matches(query: query, target: entry.item.title) ||
               SyncSearchMatcher.matches(query: query, target: entry.item.url) {
                matches.append(entry)
            }
        }
        return matches
    }

    private var folders: [String] {
        let rawFolders = Set(allBookmarks.compactMap { $0.item.folderPath })
        return Array(rawFolders).sorted()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !folders.isEmpty && searchText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Space.sm) {
                        DSChip("All", isSelected: selectedFolder == nil) {
                            selectedFolder = nil
                        }

                        ForEach(folders, id: \.self) { folder in
                            DSChip(folder, systemImage: "folder", isSelected: selectedFolder == folder) {
                                selectedFolder = (selectedFolder == folder) ? nil : folder
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.vertical, DS.Space.sm)
                }
            }

            if filteredBookmarks.isEmpty {
                DSEmptyState(
                    "No bookmarks found",
                    systemImage: "bookmark.slash",
                    message: "Bookmarks from your Mac browsers will sync here.",
                    style: .fullScreen
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredBookmarks) { entry in
                        HStack(spacing: DS.Space.md) {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(DS.Tint.bookmark)
                                .font(.system(size: DS.IconSize.row))

                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(entry.item.title.isEmpty ? entry.item.url : entry.item.title)
                                    .font(DS.Font.body)
                                    .lineLimit(1)

                                HStack(spacing: DS.Space.xs) {
                                    Text(entry.browser)
                                        .font(DS.Font.tag)
                                        .padding(.horizontal, DS.Space.xs)
                                        .padding(.vertical, DS.Space.xxs)
                                        .background(DS.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))

                                    if let folder = entry.item.folderPath, !folder.isEmpty {
                                        Text(folder)
                                            .font(DS.Font.tag)
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(entry.item.url)
                                        .font(DS.Font.meta)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let url = URL(string: entry.item.url) {
                                selectedURLForReader = url
                            }
                        }
                        .contextMenu {
                            if let url = URL(string: entry.item.url) {
                                Button {
                                    readerItem = ReaderNavigationItem(url: url, title: entry.item.title)
                                } label: {
                                    Label("Open in Reader", systemImage: "doc.plaintext")
                                }

                                Link(destination: url) {
                                    Label("Open in Safari", systemImage: "safari")
                                }

                                ShareLink(item: url) {
                                    Label("Share Link", systemImage: "square.and.arrow.up")
                                }

                                Button {
                                    UIPasteboard.general.string = entry.item.url
                                    toast = "URL Copied"
                                } label: {
                                    Label("Copy URL", systemImage: "doc.on.doc")
                                }

                                Button {
                                    SyncConsumer.shared.sendOpenOnMac(url: entry.item.url, title: entry.item.title.isEmpty ? nil : entry.item.title)
                                    toast = "Sent to Mac"
                                } label: {
                                    Label("Open on Mac", systemImage: "laptopcomputer")
                                }

                                if !entry.browser.lowercased().contains("safari") {
                                    Divider()
                                    Button(role: .destructive) {
                                        queueDeleteBookmark(entry)
                                    } label: {
                                        Label("Delete Bookmark", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Safari doesn't support deletes
                            if !entry.browser.lowercased().contains("safari") {
                                Button(role: .destructive) {
                                    queueDeleteBookmark(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .dsListRow()
                }
                .listStyle(.insetGrouped)
                .dsListStyle()
            }
        }
        .dsCanvas()
        .searchable(text: $searchText, prompt: "Search bookmarks")
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title)
        }
        .dsToast($toast, bottomInset: DS.Space.xl)
    }

    private func queueDeleteBookmark(_ entry: BookmarkRowItem) {
        let targetID = device?.id ?? ""
        SyncConsumer.shared.sendDeleteBookmark(
            bookmark: entry.item,
            browserName: entry.browser,
            profileName: entry.profile,
            targetDeviceID: targetID
        )

        toast = "Queued deletion — confirm on your Mac"
    }
}
