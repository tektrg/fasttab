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
    @State private var toastMessage: String? = nil
    @State private var showToast: Bool = false

    public init() {}

    private var displayRecentItems: [RecentAddedItem] {
        recentProvider.items(filteredByFolder: selectedFolder)
    }

    private var activeDeviceID: String {
        localCache.state.devices.first?.id ?? ""
    }

    private let carouselRows = [
        GridItem(.fixed(88), spacing: 10),
        GridItem(.fixed(88), spacing: 10)
    ]

    public static let appBackgroundGradient = LinearGradient(
        stops: [
            .init(color: Color(uiColor: UIColor { traitCollection in
                if traitCollection.userInterfaceStyle == .dark {
                    // Top: very subtle warm black in dark mode
                    return UIColor(red: 0.045, green: 0.042, blue: 0.040, alpha: 1.0)
                } else {
                    // Top: lighter warm white/stone
                    return UIColor(red: 0.988, green: 0.985, blue: 0.980, alpha: 1.0)
                }
            }), location: 0.0),
            .init(color: Color(uiColor: UIColor { traitCollection in
                if traitCollection.userInterfaceStyle == .dark {
                    // Bottom: deep black in dark mode
                    return UIColor.black
                } else {
                    // Bottom: current warm grey color
                    return UIColor(red: 0.955, green: 0.950, blue: 0.942, alpha: 1.0)
                }
            }), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    public var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
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
        .background(Self.appBackgroundGradient.ignoresSafeArea())
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
        .overlay(alignment: .bottom) {
            if showToast, let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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

    // MARK: - Section 1: Recent Added (2-Row Horizontal Carousel)

    private var recentAddedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Text("Recent Added")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    if let selectedFolder {
                        let leaf = BookmarkTreeBuilder.splitPath(selectedFolder).last ?? selectedFolder
                        Text("in \(leaf)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text("\(displayRecentItems.count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            if displayRecentItems.isEmpty {
                emptyRecentCard
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: carouselRows, spacing: 12) {
                        ForEach(displayRecentItems) { item in
                            let (delTitle, delIcon) = recentDeleteInfo(for: item)
                            ReadingFeedCardView(
                                title: item.title,
                                url: item.url,
                                domain: item.domain,
                                badgeText: item.source.badgeText,
                                badgeTint: item.source.tintColor,
                                fixedWidth: 310,
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Section 2: Emerging (2-Row Horizontal Carousel)

    private var emergingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Emerging")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                Button {
                    withAnimation {
                        emergingProvider.refresh()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Shuffle")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.purple.opacity(0.12))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            if emergingProvider.items.isEmpty {
                if emergingProvider.isProcessing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    emptyEmergingCard
                        .padding(.horizontal, 16)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: carouselRows, spacing: 12) {
                        ForEach(emergingProvider.items) { item in
                            let (delTitle, delIcon) = emergingDeleteInfo(for: item)
                            ReadingFeedCardView(
                                title: item.title,
                                url: item.url,
                                domain: item.domain,
                                badgeText: item.badgeText,
                                badgeTint: .purple,
                                fixedWidth: 310,
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
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Section 3: Last Opened on iPhone (2-Row Horizontal Carousel)

    private var lastOpenedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Last Opened")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer()

                if !lastOpenedStore.items.isEmpty {
                    Button {
                        withAnimation {
                            lastOpenedStore.clear()
                        }
                    } label: {
                        Text("Clear")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)

            if lastOpenedStore.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No recently opened articles")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Articles you read in FastTab will appear here for easy resuming.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(ReadingFeedCardView.cardBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: carouselRows, spacing: 12) {
                        ForEach(lastOpenedStore.items.prefix(16)) { item in
                            if let url = item.parsedURL {
                                let (delTitle, delIcon) = lastOpenedDeleteInfo(for: url)
                                ReadingFeedCardView(
                                    title: item.title,
                                    url: url,
                                    domain: item.domain,
                                    badgeText: "Opened on iPhone",
                                    badgeTint: .teal,
                                    fixedWidth: 310,
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyRecentCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.square.dashed")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text("No recent additions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Save links via the FastTab Share Sheet or sync bookmarks from your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(ReadingFeedCardView.cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var emptyEmergingCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.purple.opacity(0.8))

            VStack(alignment: .leading, spacing: 3) {
                Text("No emerging links yet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Browse pages on your Mac or iPhone to see connected recommendations here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(ReadingFeedCardView.cardBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Deletion Helpers

    private func recentDeleteInfo(for item: RecentAddedItem) -> (title: String, icon: String) {
        switch item.source {
        case .bookmark:
            return ("Delete Bookmark", "trash")
        case .shareSheet:
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

