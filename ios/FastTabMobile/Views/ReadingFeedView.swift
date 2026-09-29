import SwiftUI
import TipKit
import FastTabSync

public struct ReadingFeedView: View {
    @ObservedObject private var recentProvider = RecentAddedProvider.shared
    @ObservedObject private var emergingProvider = EmergingContentProvider.shared
    @ObservedObject private var lastOpenedStore = LastOpenedStore.shared
    @ObservedObject private var localCache = LocalCache.shared
    @ObservedObject private var readingProgress = ReaderReadingProgress.shared
    @ObservedObject private var highlightStore = ReaderHighlightStore.shared

    @State private var selectedFolder: String? = nil
    @State private var readerItem: ReaderNavigationItem? = nil
    @State private var saveToBookmarkURL: URL? = nil
    @State private var saveToBookmarkTitle: String = ""
    @State private var toast: String? = nil

    public init() {}

    private var displayRecentItems: [RecentAddedItem] {
        recentProvider.items(filteredByFolder: selectedFolder)
    }

    private let emergingLanesTip = EmergingLanesTip()

    private var activeDeviceID: String {
        localCache.state.connectedMac?.id ?? ""
    }

    /// Most recently opened article that isn't finished yet (progress < 95%).
    /// Source of truth is `LastOpenedStore` (the "most open"), merged live with
    /// `ReaderReadingProgress` so a just-closed reader updates without a reload.
    /// Capped at 1 — a single resume chip, like a one-item switcher.
    private var unfinishedReads: [LastOpenedItem] {
        let finishedThreshold = 0.95
        return lastOpenedStore.items.filter { item in
            effectiveProgress(for: item) < finishedThreshold
        }.prefix(1).map { $0 }
    }

    private func effectiveProgress(for item: LastOpenedItem) -> Double {
        guard let url = item.parsedURL else { return item.readingProgress }
        return max(item.readingProgress, readingProgress.progress(for: url))
    }

    /// Best display title for a resume chip: a real article title when we have
    /// one, the website (domain) only as a fallback. `LastOpenedItem.title`
    /// degrades to the bare host when an article was opened without a title
    /// (e.g. from the Tabs tab), so in that case look the URL up in the feed
    /// providers, which usually carry the synced bookmark/tab title.
    private func displayTitle(for item: LastOpenedItem) -> String {
        let hostFallback = item.domain.isEmpty ? (item.parsedURL?.host() ?? item.url) : item.domain
        if !item.title.isEmpty && item.title.lowercased() != hostFallback.lowercased() {
            return item.title
        }
        if let url = item.parsedURL {
            let key = url.absoluteString.lowercased()
            if let recent = recentProvider.items(filteredByFolder: nil)
                .first(where: { $0.url.absoluteString.lowercased() == key }),
               !recent.title.isEmpty {
                return recent.title
            }
            if let emerging = emergingProvider.items
                .first(where: { $0.url.absoluteString.lowercased() == key }),
               !emerging.title.isEmpty {
                return emerging.title
            }
        }
        if !item.title.isEmpty { return item.title }
        return hostFallback
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

                // Section 4: Recent Highlights
                recentHighlightsSection

                Spacer(minLength: 40)
            }
            .padding(.top, 6)
            .padding(.bottom, unfinishedReads.isEmpty ? 24 : DS.Space.floatingBarClearance)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SyncWarningBanner()
        }
        .dsCanvas()
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !unfinishedReads.isEmpty {
                FloatingContinueReadingBar(
                    items: unfinishedReads,
                    title: { displayTitle(for: $0) },
                    progress: { effectiveProgress(for: $0) },
                    onSelect: { item in
                        guard let url = item.parsedURL else { return }
                        openArticle(url: url, title: displayTitle(for: item))
                    }
                )
                .padding(.bottom, DS.Space.sm)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addLinksFromClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .accessibilityLabel("Add from clipboard")
            }
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
            ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
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
        .dsToast($toast, bottomInset: unfinishedReads.isEmpty ? DS.Space.xl : DS.Space.floatingBarClearance)
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
                TipView(emergingLanesTip)
                    .fastTabTipStyle()
                    .padding(.horizontal, DS.Space.gutter)
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
                            emergingLanesTip.invalidate(reason: .actionPerformed)
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

    // MARK: - Section 4: Recent Highlights

    /// Newest 12 highlights across every article. "See all" pushes the full,
    /// article-grouped list onto this tab's own `NavigationStack`.
    private var recentHighlightsSection: some View {
        let recent = Array(highlightStore.allHighlightsNewestFirst().prefix(12))

        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            DSSectionHeader("Recent Highlights") {
                NavigationLink {
                    HighlightsListView()
                } label: {
                    HStack(spacing: 2) {
                        Text("See all")
                        Image(systemName: "chevron.right")
                    }
                }
                .font(DS.Font.control)
                .foregroundStyle(.secondary)
            }

            if recent.isEmpty {
                DSEmptyState(
                    "No highlights yet",
                    systemImage: "highlighter",
                    message: "Long-press any text in the article reader to save a highlight.",
                    style: .inline
                )
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, DS.Space.xs)
            } else {
                carousel(recent) { highlight in
                    HighlightSnippetRow(
                        highlight: highlight,
                        articleTitle: ReaderHighlightTitleResolver.resolve(for: highlight),
                        style: .card
                    ) {
                        openHighlight(highlight)
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
        ) {
            OnboardingShortcutButton(shortcut: .addToShareSheet, prominence: .inline)
        }
    }

    private var emptyEmergingCard: some View {
        DSEmptyState(
            "No emerging links yet",
            systemImage: "sparkles",
            message: "Browse pages on your Mac or iPhone to see connected recommendations here.",
            tint: DS.Tint.emerging,
            style: .inline
        ) {
            if localCache.state.connectedMac == nil {
                OnboardingShortcutButton(shortcut: .connectMac, prominence: .inline)
            }
        }
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

    private func openArticle(url: URL, title: String, focusHighlightID: String? = nil) {
        lastOpenedStore.recordOpened(url: url, title: title)
        readerItem = ReaderNavigationItem(url: url, title: title, focusHighlightID: focusHighlightID)
    }

    private func openHighlight(_ highlight: ReaderHighlight) {
        guard let url = highlight.articleURL else { return }
        let title = ReaderHighlightTitleResolver.resolve(for: highlight)
        openArticle(url: url, title: title, focusHighlightID: highlight.id)
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

    /// Reads the pasteboard only on this tap, so the iOS paste prompt follows
    /// an intentional action. Saves through the "Save to iPhone" store.
    private func addLinksFromClipboard() {
        let urls = ClipboardLinkExtractor.links(in: UIPasteboard.general.string ?? "")
        guard !urls.isEmpty else {
            presentToast("No links in clipboard")
            return
        }
        SavedOnIPhoneStore.shared.add(urls.map { SavedOnIPhoneLink(url: $0.absoluteString, title: $0.host()) })
        presentToast(urls.count == 1 ? "Added 1 link" : "Added \(urls.count) links")
    }

    private func presentToast(_ message: String) {
        toast = message
    }
}

/// Bottom floating switcher for the single most recent unfinished read — the
/// Read tab's answer to the Tabs tab's `FloatingTabSortBar`. Same capsule /
/// ultraThinMaterial / border / shadow styling with one resume chip. Tapping
/// it reopens the reader, which restores the saved scroll position via
/// `ReaderViewModel.loadInitialState()`.
public struct FloatingContinueReadingBar: View {
    public let items: [LastOpenedItem]
    public let title: (LastOpenedItem) -> String
    public let progress: (LastOpenedItem) -> Double
    public let onSelect: (LastOpenedItem) -> Void

    /// Fetched link previews by item id. The Last Opened cards display
    /// `LinkPreview.cardTitle` (the site's own title, e.g. a tweet's text) —
    /// the chip resolves the same way so it never shows a bare domain while
    /// the card right above it shows a real title.
    @State private var previews: [String: LinkPreview] = [:]

    public init(
        items: [LastOpenedItem],
        title: @escaping (LastOpenedItem) -> String,
        progress: @escaping (LastOpenedItem) -> Double,
        onSelect: @escaping (LastOpenedItem) -> Void
    ) {
        self.items = items
        self.title = title
        self.progress = progress
        self.onSelect = onSelect
    }

    private func label(for item: LastOpenedItem) -> String {
        LinkPreview.cardTitle(storedTitle: title(item), preview: previews[item.id])
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.xs) {
                ForEach(items) { item in
                    let pct = min(max(progress(item), 0), 1)
                    let label = label(for: item)
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        onSelect(item)
                    } label: {
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "book")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(DS.Tint.action)
                            Text(label)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .frame(maxWidth: 240, alignment: .leading)
                            if pct > 0.01 {
                                ReadingProgressRing(progress: pct)
                            }
                        }
                        .padding(.horizontal, DS.Space.md)
                        .padding(.vertical, DS.Space.sm)
                        .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Continue reading \(label), \(Int((pct * 100).rounded())) percent read")
                }
            }
        }
        .scrollClipDisabled()
        .task(id: items.map(\.id)) {
            for item in items {
                guard let url = item.parsedURL, previews[item.id] == nil else { continue }
                previews[item.id] = await LinkPreviewLoader.shared.preview(for: url)
            }
        }
        .padding(DS.Space.xs)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.45),
                            Color.white.opacity(0.15)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        )
        .dsShadow(.floating)
        .padding(.horizontal, DS.Space.lg)
    }
}

/// Thin circular reading-progress ring for the resume chip. Track + tinted
/// arc, no numbers — VoiceOver still announces the percent via the chip label.
private struct ReadingProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    DS.Tint.action,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}
