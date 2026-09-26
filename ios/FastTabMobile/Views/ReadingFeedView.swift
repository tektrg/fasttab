import SwiftUI
import FastTabSync

public struct ReadingFeedView: View {
    @ObservedObject private var recentProvider = RecentAddedProvider.shared
    @ObservedObject private var emergingProvider = EmergingContentProvider.shared
    @ObservedObject private var lastOpenedStore = LastOpenedStore.shared
    @ObservedObject private var localCache = LocalCache.shared
    @ObservedObject private var readingProgress = ReaderReadingProgress.shared

    @State private var selectedFolder: String? = nil
    @State private var readerItem: ReaderNavigationItem? = nil
    @State private var saveToBookmarkURL: URL? = nil
    @State private var saveToBookmarkTitle: String = ""
    @State private var toast: String? = nil

    public init() {}

    private var displayRecentItems: [RecentAddedItem] {
        recentProvider.items(filteredByFolder: selectedFolder)
    }

    private var activeDeviceID: String {
        localCache.state.devices.first?.id ?? ""
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                // Top Bookmark Folder Filter Chips (YouTube Music style)
                if !recentProvider.availableFolders.isEmpty {
                    ReadingFolderChipsView(
                        folders: recentProvider.availableFolders,
                        selectedFolder: $selectedFolder
                    )
                }

                // Section 1: Recent Added (Horizontal Carousel)
                recentAddedSection

                // Section 2: Emerging (Related to Mac & iOS Reading)
                emergingSection

                // Section 3: Last Opened on iPhone
                lastOpenedSection

                Spacer(minLength: 40)
            }
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .dsCanvas()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
        }
        .refreshable {
            await refreshAllAsync()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title)
        }
        .sheet(item: $saveToBookmarkURL) { url in
            BookmarkMovePicker(
                sourceDeviceID: activeDeviceID,
                title: "Save to Mac Bookmarks"
            ) { destination in
                SyncConsumer.shared.sendAddBookmark(
                    title: saveToBookmarkTitle.isEmpty ? (url.host() ?? url.absoluteString) : saveToBookmarkTitle,
                    url: url.absoluteString,
                    destinationBrowserName: destination.browserName,
                    destinationProfileName: destination.profileName,
                    destinationFolderPath: destination.folderPath,
                    targetDeviceID: activeDeviceID
                )
                presentToast("Saved to \(destination.folderDisplayName)")
                saveToBookmarkURL = nil
            }
        }
        .dsToast($toast)
        .onAppear {
            recentProvider.drainPendingShares()
            recentProvider.refresh()
            emergingProvider.refresh()
        }
        .onChange(of: recentProvider.availableFolders) { _, newFolders in
            if let current = selectedFolder, !newFolders.contains(where: { $0.fullPath == current }) {
                selectedFolder = nil
            }
        }
    }

    // MARK: - Carousel

    /// One-row horizontal carousel of vertical cards. Each card is 5/9 of the visible
    /// width, so about 1.8 cards show and the peeking second card invites a swipe.
    /// Snaps card by card.
    private func carousel<Items: RandomAccessCollection, Card: View>(
        _ items: Items,
        @ViewBuilder card: @escaping (Items.Element) -> Card
    ) -> some View where Items.Element: Identifiable {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: DS.Space.md) {
                ForEach(items) { item in
                    card(item)
                        .containerRelativeFrame(.horizontal, count: 9, span: 5, spacing: DS.Space.md)
                }
            }
            .scrollTargetLayout()
            // Room for the card shadow, which a scroll view would otherwise clip.
            .padding(.top, DS.Space.sm)
            .padding(.bottom, DS.Space.lg)
        }
        .contentMargins(.horizontal, DS.Space.gutter, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }

    // MARK: - Section 1: Recent Added

    private var recentAddedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSSectionHeader(
                "Recent Added",
                context: selectedFolder.map { "in \(BookmarkTreeBuilder.splitPath($0).last ?? $0)" }
            ) {
                DSCountPill(displayRecentItems.count)
            }

            if displayRecentItems.isEmpty {
                emptyRecentCard
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.top, DS.Space.xs)
            } else {
                carousel(displayRecentItems) { item in
                    let (delTitle, delIcon) = recentDeleteInfo(for: item)
                    ReadingFeedCardView(
                        title: item.title,
                        url: item.url,
                        domain: item.domain,
                        badgeText: item.source.badgeText,
                        badgeTint: item.source.tintColor,
                        badgeIcon: item.source.iconName,
                        readingProgress: readingProgress.progress(for: item.url),
                        deleteTitle: delTitle,
                        deleteIcon: delIcon,
                        onSelect: {
                            openArticle(url: item.url, title: item.title)
                        },
                        onOpenOnMac: {
                            openOnMac(url: item.url, title: item.title)
                        },
                        onSaveToBookmarks: {
                            promptSaveBookmark(url: item.url, title: item.title)
                        },
                        onDelete: {
                            deleteRecentItem(item)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Section 2: Emerging (Related to Mac & iOS Reading)

    private var emergingSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSSectionHeader("Emerging") {
                Button {
                    withAnimation {
                        emergingProvider.refresh()
                    }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.dsTinted(DS.Tint.emerging))
            }

            if emergingProvider.items.isEmpty {
                if emergingProvider.isProcessing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Space.xl)
                } else {
                    emptyEmergingCard
                        .padding(.horizontal, DS.Space.gutter)
                        .padding(.top, DS.Space.xs)
                }
            } else {
                carousel(emergingProvider.items) { item in
                    let (delTitle, delIcon) = emergingDeleteInfo(for: item)
                    ReadingFeedCardView(
                        title: item.title,
                        url: item.url,
                        domain: item.domain,
                        badgeText: item.badgeText,
                        badgeTint: DS.Tint.emerging,
                        badgeIcon: "sparkles",
                        readingProgress: readingProgress.progress(for: item.url),
                        deleteTitle: delTitle,
                        deleteIcon: delIcon,
                        onSelect: {
                            openArticle(url: item.url, title: item.title)
                        },
                        onOpenOnMac: {
                            openOnMac(url: item.url, title: item.title)
                        },
                        onSaveToBookmarks: {
                            promptSaveBookmark(url: item.url, title: item.title)
                        },
                        onDelete: {
                            deleteEmergingItem(item)
                        },
                        onMarkNotARead: { wholeWebsite in
                            markEmergingItemNotARead(item, wholeWebsite: wholeWebsite)
                        }
                    )
                }
            }
        }
    }

    // MARK: - Section 3: Last Opened on iPhone

    private var lastOpenedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSSectionHeader("Last Opened") {
                if !lastOpenedStore.items.isEmpty {
                    Button("Clear") {
                        withAnimation {
                            lastOpenedStore.clear()
                        }
                    }
                    .font(DS.Font.control)
                    .foregroundStyle(.secondary)
                }
            }

            if lastOpenedStore.items.isEmpty {
                DSEmptyState(
                    "No recently opened articles",
                    systemImage: "book.closed",
                    message: "Articles you read in FastTab will appear here for easy resuming.",
                    tint: DS.Tint.recent,
                    style: .inline
                )
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, DS.Space.xs)
            } else {
                carousel(lastOpenedStore.items.prefix(16)) { item in
                    if let url = item.parsedURL {
                        let (delTitle, delIcon) = lastOpenedDeleteInfo(for: url)
                        ReadingFeedCardView(
                            title: item.title,
                            url: url,
                            domain: item.domain,
                            badgeText: "Opened on iPhone",
                            badgeTint: DS.Tint.recent,
                            badgeIcon: "iphone",
                            readingProgress: item.readingProgress,
                            deleteTitle: delTitle,
                            deleteIcon: delIcon,
                            onSelect: {
                                openArticle(url: url, title: item.title)
                            },
                            onOpenOnMac: {
                                openOnMac(url: url, title: item.title)
                            },
                            onSaveToBookmarks: {
                                promptSaveBookmark(url: url, title: item.title)
                            },
                            onDelete: {
                                deleteLastOpenedItem(item, url: url)
                            }
                        )
                    }
                }
            }
        }
    }

    private var emptyRecentCard: some View {
        DSEmptyState(
            "No recent additions",
            systemImage: "plus.square.dashed",
            message: "Save links via the FastTab Share Sheet or sync bookmarks from your Mac.",
            style: .inline
        )
    }

    private var emptyEmergingCard: some View {
        DSEmptyState(
            "No emerging links yet",
            systemImage: "sparkles",
            message: "Browse pages on your Mac or iPhone to see connected recommendations here.",
            tint: DS.Tint.emerging,
            style: .inline
        )
    }

    // MARK: - Deletion Helpers

    private func recentDeleteInfo(for item: RecentAddedItem) -> (title: String, icon: String) {
        switch item.source {
        case .bookmark:
            return ("Delete Bookmark", "trash")
        case .shareSheet:
            return ("Delete Link", "trash")
        case .savedOnIPhone:
            return ("Delete Link", "trash")
        }
    }

    private func deleteRecentItem(_ item: RecentAddedItem) {
        switch item.source {
        case .bookmark(let browser, _, let bookmark, let profileName, let deviceID):
            SyncConsumer.shared.sendDeleteBookmark(
                bookmark: bookmark,
                browserName: browser,
                profileName: profileName,
                targetDeviceID: deviceID
            )
            LocalCache.shared.removeBookmark(id: bookmark.id)
            withAnimation {
                recentProvider.removeItem(id: item.id)
            }
            presentToast("Queued delete — confirm on your Mac")
        case .shareSheet(let commandID, _):
            SyncConsumer.shared.cancelQueuedCommand(id: commandID)
            LocalCache.shared.removeSentCommand(id: commandID)
            withAnimation {
                recentProvider.removeItem(id: item.id)
            }
            presentToast("Removed link")
        case .savedOnIPhone(let linkID):
            SavedOnIPhoneStore.shared.remove(id: linkID)
            withAnimation {
                recentProvider.removeItem(id: item.id)
            }
            presentToast("Removed link")
        }
    }

    private func emergingDeleteInfo(for item: EmergingItem) -> (title: String, icon: String) {
        switch item.source {
        case .bookmark:
            return ("Delete Bookmark", "trash")
        case .tab:
            return ("Close Tab", "xmark.circle")
        case .generic:
            if LocalCache.shared.findBookmark(url: item.url) != nil {
                return ("Delete Bookmark", "trash")
            } else if LocalCache.shared.findTab(url: item.url) != nil {
                return ("Close Tab", "xmark.circle")
            } else {
                return ("Delete Link", "trash")
            }
        }
    }

    private func deleteEmergingItem(_ item: EmergingItem) {
        switch item.source {
        case .bookmark(let bookmark, let browserName, let profileName, let deviceID):
            SyncConsumer.shared.sendDeleteBookmark(
                bookmark: bookmark,
                browserName: browserName,
                profileName: profileName,
                targetDeviceID: deviceID
            )
            LocalCache.shared.removeBookmark(id: bookmark.id)
            withAnimation {
                emergingProvider.removeItem(id: item.id)
            }
            presentToast("Queued delete — confirm on your Mac")
        case .tab(let tab):
            SyncConsumer.shared.sendCloseTab(tab)
            LocalCache.shared.removeTab(id: tab.id)
            withAnimation {
                emergingProvider.removeItem(id: item.id)
            }
            let devName = localCache.state.devices.first { $0.id == tab.deviceID }?.name ?? "your Mac"
            presentToast("Close queued for \(devName)")
        case .generic:
            if let match = LocalCache.shared.findBookmark(url: item.url) {
                SyncConsumer.shared.sendDeleteBookmark(
                    bookmark: match.bookmark,
                    browserName: match.browserName,
                    profileName: match.profileName,
                    targetDeviceID: match.deviceID
                )
                LocalCache.shared.removeBookmark(id: match.bookmark.id)
                withAnimation {
                    emergingProvider.removeItem(id: item.id)
                }
                presentToast("Queued delete — confirm on your Mac")
            } else if let tab = LocalCache.shared.findTab(url: item.url) {
                SyncConsumer.shared.sendCloseTab(tab)
                LocalCache.shared.removeTab(id: tab.id)
                withAnimation {
                    emergingProvider.removeItem(id: item.id)
                }
                let devName = localCache.state.devices.first { $0.id == tab.deviceID }?.name ?? "your Mac"
                presentToast("Close queued for \(devName)")
            } else {
                withAnimation {
                    emergingProvider.removeItem(id: item.id)
                }
                presentToast("Removed link")
            }
        }
    }

    private func markEmergingItemNotARead(_ item: EmergingItem, wholeWebsite: Bool) {
        withAnimation {
            if wholeWebsite {
                emergingProvider.markHostNotARead(item)
                presentToast("Won't suggest \(item.domain) again")
            } else {
                emergingProvider.markLinkNotARead(item)
                presentToast("Won't suggest this link again")
            }
        }
    }

    private func lastOpenedDeleteInfo(for url: URL) -> (title: String, icon: String) {
        if LocalCache.shared.findBookmark(url: url) != nil {
            return ("Delete Bookmark", "trash")
        } else if LocalCache.shared.findTab(url: url) != nil {
            return ("Close Tab", "xmark.circle")
        } else {
            return ("Delete Link", "trash")
        }
    }

    private func deleteLastOpenedItem(_ item: LastOpenedItem, url: URL) {
        if let match = LocalCache.shared.findBookmark(url: url) {
            SyncConsumer.shared.sendDeleteBookmark(
                bookmark: match.bookmark,
                browserName: match.browserName,
                profileName: match.profileName,
                targetDeviceID: match.deviceID
            )
            LocalCache.shared.removeBookmark(id: match.bookmark.id)
            withAnimation {
                lastOpenedStore.remove(id: item.id)
            }
            presentToast("Queued delete — confirm on your Mac")
        } else if let tab = LocalCache.shared.findTab(url: url) {
            SyncConsumer.shared.sendCloseTab(tab)
            LocalCache.shared.removeTab(id: tab.id)
            withAnimation {
                lastOpenedStore.remove(id: item.id)
            }
            let devName = localCache.state.devices.first { $0.id == tab.deviceID }?.name ?? "your Mac"
            presentToast("Close queued for \(devName)")
        } else {
            withAnimation {
                lastOpenedStore.remove(id: item.id)
            }
            presentToast("Removed from Recents")
        }
    }

    // MARK: - Actions

    private func openArticle(url: URL, title: String) {
        lastOpenedStore.recordOpened(url: url, title: title)
        readerItem = ReaderNavigationItem(url: url, title: title)
    }

    private func openOnMac(url: URL, title: String) {
        SyncConsumer.shared.sendOpenOnMac(url: url.absoluteString, title: title)
        presentToast("Sent to Mac")
    }

    private func promptSaveBookmark(url: URL, title: String) {
        saveToBookmarkTitle = title
        saveToBookmarkURL = url
    }

    private func refreshAll() {
        recentProvider.drainPendingShares()
        Task {
            await SyncConsumer.shared.refreshNow()
            recentProvider.refresh()
            emergingProvider.refresh()
        }
    }

    private func refreshAllAsync() async {
        recentProvider.drainPendingShares()
        await SyncConsumer.shared.refreshNow()
        recentProvider.refresh()
        emergingProvider.refresh()
    }

    private func presentToast(_ message: String) {
        toast = message
    }
}
