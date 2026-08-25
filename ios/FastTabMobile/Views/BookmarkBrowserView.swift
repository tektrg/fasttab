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
    @State private var toastMessage: String?
    @State private var showToast: Bool = false

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
                results.append(BookmarkRowItem(browser: blob.browserName, profile: blob.profileName, item: bm))
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
            DataFreshnessBanner(device: device, lastSyncedAt: localCache.state.lastSyncedAt)

            if !folders.isEmpty && searchText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedFolder = nil
                        } label: {
                            Text("All")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedFolder == nil ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
                                .foregroundColor(selectedFolder == nil ? .white : .primary)
                                .cornerRadius(14)
                        }

                        ForEach(folders, id: \.self) { folder in
                            Button {
                                selectedFolder = (selectedFolder == folder) ? nil : folder
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                    Text(folder)
                                }
                                .font(.caption)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedFolder == folder ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
                                .foregroundColor(selectedFolder == folder ? .white : .primary)
                                .cornerRadius(14)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            if filteredBookmarks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No bookmarks found")
                        .font(.headline)
                    Text("Bookmarks from your Mac browsers will sync here.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredBookmarks) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: "bookmark.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 18))

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.item.title.isEmpty ? entry.item.url : entry.item.title)
                                    .font(.body)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(entry.browser)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(uiColor: .tertiarySystemBackground))
                                        .cornerRadius(4)

                                    if let folder = entry.item.folderPath, !folder.isEmpty {
                                        Text(folder)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }

                                    Text(entry.item.url)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
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
                }
                .listStyle(.insetGrouped)
            }
        }
        .searchable(text: $searchText, prompt: "Search bookmarks")
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if showToast, let toastMessage {
                Text(toastMessage)
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .shadow(radius: 4)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func queueDeleteBookmark(_ entry: BookmarkRowItem) {
        let targetID = device?.id ?? ""
        SyncConsumer.shared.sendDeleteBookmark(
            bookmark: entry.item,
            browserName: entry.browser,
            profileName: entry.profile,
            targetDeviceID: targetID
        )

        withAnimation {
            toastMessage = "Queued deletion — confirm on your Mac"
            showToast = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation {
                showToast = false
            }
        }
    }
}
