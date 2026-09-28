import SwiftUI
import FastTabSync

/// Where a `RandomCardItem` came from — shown as the small badge on each card,
/// used to build the card's skip id (a bookmark and an open tab pointing at
/// the same URL are tracked separately), and carries what a long-press action
/// (delete/close/move) needs to build the matching `SyncConsumer` command.
enum RandomCardSource: Hashable {
    case bookmark(item: SyncedBookmarkItem, source: BookmarkSource)
    case openTab(tab: SyncedTab)

    var badgeText: String {
        switch self {
        case .bookmark(let item, _):
            guard let folderPath = item.folderPath, !folderPath.isEmpty else { return "Bookmark" }
            return folderPath
        case .openTab(let tab):
            return "Open tab · \(tab.browserName)"
        }
    }

    /// Safari bookmarks are never writable — same gate `BookmarkNodeRow` uses
    /// to hide its own Delete/Move swipe actions and context-menu items.
    var isWritableBookmark: Bool {
        guard case .bookmark(_, let source) = self else { return false }
        return !source.browserName.lowercased().contains("safari")
    }
}

struct RandomCardItem: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
    let source: RandomCardSource
}

enum RandomCardDecision {
    case moveTo
    case skip
}

/// A long-press action on a card. Delete/close fire immediately; move opens
/// `BookmarkMovePicker` first, so it's handled as a separate `moveRequest`
/// rather than a case here.
enum RandomCardMenuAction {
    case deleteBookmark
    case moveBookmark
    case closeTab
    case openOnMac
    case openInReader
    case copyURL
}

public struct RandomLinksView: View {
    @ObservedObject private var localCache = LocalCache.shared
    @ObservedObject private var skipStore = RandomFeedSkipStore.shared

    @State private var deck: [RandomCardItem] = []
    @State private var hasBuiltInitialDeck = false
    @State private var readerItem: ReaderNavigationItem?
    @State private var moveRequest: RandomCardItem?
    @State private var toast: String?
    @State private var expandingItemID: String?
    @State private var isExpanding = false

    private static let maxDeckSize = 40
    private static let visibleCardCount = 3

    public init() {}

    public var body: some View {
        VStack {
            if deck.isEmpty {
                emptyState
            } else {
                deckStack
                    .padding(DS.Space.gutter)
            }
        }
        .dsCanvas()
        .navigationTitle("Shuffle")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    reshuffle()
                } label: {
                    Image(systemName: "shuffle")
                }
                .disabled(!hasAnySourceData)
            }
        }
        .onAppear {
            guard !hasBuiltInitialDeck else { return }
            hasBuiltInitialDeck = true
            reshuffle()
        }
        .fullScreenCover(item: $readerItem) { item in
            ReaderView(url: item.url, title: item.title, focusHighlightID: item.focusHighlightID)
        }
        .sheet(item: $moveRequest) { item in
            switch item.source {
            case .bookmark(let bookmark, let source):
                BookmarkMovePicker(
                    sourceDeviceID: source.deviceID,
                    folderMoveExclusion: item.source.isWritableBookmark ? FolderMoveExclusion(
                        path: BookmarkTreeBuilder.splitPath(bookmark.folderPath ?? ""),
                        profileKeys: ["\(source.browserName)|\(source.profileName)"],
                        includeSubpaths: false
                    ) : nil,
                    title: item.source.isWritableBookmark ? "Move to…" : "Save to…"
                ) { destination in
                    if item.source.isWritableBookmark {
                        performMove(item, bookmark: bookmark, source: source, to: destination)
                    } else {
                        performSave(item, title: bookmark.title, url: bookmark.url, deviceID: source.deviceID, to: destination)
                    }
                }
            case .openTab(let tab):
                BookmarkMovePicker(
                    sourceDeviceID: tab.deviceID,
                    title: "Save to…"
                ) { destination in
                    performSave(item, title: tab.title, url: tab.url, deviceID: tab.deviceID, to: destination)
                }
            }
        }
        .dsToast($toast)
        // The Shuffle widget mirrors whatever card is on top here.
        .onChange(of: deck.first?.id) { _, _ in
            WidgetSnapshotPublisher.shared.shuffleTopCardChanged(deck.first)
        }
    }

    private var deckStack: some View {
        GeometryReader { geometry in
            let cardSize = Self.cardSize(fitting: geometry.size)
            let deckWidth = geometry.size.width
            let deckHeight = geometry.size.height
            ZStack {
                ForEach(Array(deck.prefix(Self.visibleCardCount).enumerated()).reversed(), id: \.element.id) { index, item in
                    let isTarget = expandingItemID == item.id
                    let isTop = index == 0
                    let scaleTarget = (isTarget && isExpanding)
                        ? max(deckWidth / cardSize.width, deckHeight / cardSize.height)
                        : (1 - CGFloat(index) * 0.04)
                    let yTarget = (isTarget && isExpanding) ? 0 : CGFloat(index) * 10
                    let opacityTarget: Double = isExpanding
                        ? (isTarget ? 1.0 : 0.0)
                        : 1.0

                    RandomCardView(
                        item: item,
                        isTop: isTop,
                        cardSize: cardSize,
                        isExpanding: isTarget && isExpanding,
                        onTap: {
                            animateCardOpen(item)
                        },
                        onDecision: { decision in
                            handle(decision, for: item)
                        },
                        onMenuAction: { action in
                            handleMenuAction(action, for: item)
                        }
                    )
                    .scaleEffect(scaleTarget)
                    .offset(y: yTarget)
                    .opacity(opacityTarget)
                    .zIndex(isTarget ? 999 : Double(Self.visibleCardCount - index))
                    .allowsHitTesting(isTop && !isExpanding)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func animateCardOpen(_ item: RandomCardItem) {
        guard !isExpanding else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        expandingItemID = item.id
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            isExpanding = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            readerItem = ReaderNavigationItem(url: item.url, title: item.title)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isExpanding = false
                expandingItemID = nil
            }
        }
    }

    /// Largest 3:4 rectangle that fits inside the space the tab has to offer.
    /// Cards get an explicit, bounded size rather than relying on `aspectRatio`
    /// alone — an unconstrained card would size itself off the fetched preview
    /// image's own pixel dimensions instead of the screen, pushing its title
    /// text off the bottom of the visible area.
    private static func cardSize(fitting available: CGSize) -> CGSize {
        let widthLimited = CGSize(width: available.width, height: available.width * 4 / 3)
        if widthLimited.height <= available.height {
            return widthLimited
        }
        return CGSize(width: available.height * 3 / 4, height: available.height)
    }

    private var hasAnySourceData: Bool {
        !localCache.state.bookmarkBlobs.isEmpty || !localCache.state.tabs.isEmpty
    }

    private var emptyState: some View {
        Group {
            if hasAnySourceData {
                DSEmptyState(
                    "You've been through today's picks",
                    systemImage: "checkmark.circle",
                    message: "Skipped links come back tomorrow — or right now."
                ) {
                    Button("Shuffle again") {
                        skipStore.resetToday()
                        reshuffle()
                    }
                    .buttonStyle(.dsPrimary)
                }
            } else {
                DSEmptyState(
                    "Nothing to shuffle yet",
                    systemImage: "shuffle",
                    message: "Bookmarks and open tabs from your Mac will show up here once they sync."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handle(_ decision: RandomCardDecision, for item: RandomCardItem) {
        switch decision {
        case .moveTo:
            moveRequest = item
        case .skip:
            skipStore.skip(item.id)
            deck.removeAll { $0.id == item.id }
        }
    }

    /// Delete/close are fire-and-forget from this view's perspective: the
    /// command is queued the same way the Bookmarks/Tabs tabs queue theirs,
    /// a toast confirms it, and the card leaves the deck immediately — same
    /// as a skip. No pending-action tracking here (see plan increment 2):
    /// those tabs are the authoritative place a failure surfaces, and a
    /// failed delete simply means the item can legitimately reappear on a
    /// future reshuffle, because the pool always rebuilds fresh from
    /// `LocalCache`.
    private func handleMenuAction(_ action: RandomCardMenuAction, for item: RandomCardItem) {
        switch action {
        case .deleteBookmark:
            guard case .bookmark(let bookmark, let source) = item.source else { return }
            SyncConsumer.shared.sendDeleteBookmark(
                bookmark: bookmark,
                browserName: source.browserName,
                profileName: source.profileName,
                targetDeviceID: source.deviceID
            )
            presentToast("Queued delete — confirm on your Mac")
            deck.removeAll { $0.id == item.id }
        case .closeTab:
            guard case .openTab(let tab) = item.source else { return }
            SyncConsumer.shared.sendCloseTab(tab)
            presentToast("Queued close — confirm on your Mac")
            deck.removeAll { $0.id == item.id }
        case .openOnMac:
            guard case .openTab(let tab) = item.source else { return }
            SyncConsumer.shared.sendOpenOnMac(url: tab.url, title: tab.title.isEmpty ? nil : tab.title)
            presentToast("Sent to Mac")
        case .moveBookmark:
            moveRequest = item
        case .openInReader:
            readerItem = ReaderNavigationItem(url: item.url, title: item.title)
        case .copyURL:
            UIPasteboard.general.string = item.url.absoluteString
            presentToast("URL Copied")
        }
    }

    private func performMove(
        _ item: RandomCardItem,
        bookmark: SyncedBookmarkItem,
        source: BookmarkSource,
        to destination: BookmarkMoveDestination
    ) {
        SyncConsumer.shared.sendMoveBookmark(
            bookmark: bookmark,
            sourceBrowserName: source.browserName,
            sourceProfileName: source.profileName,
            destinationBrowserName: destination.browserName,
            destinationProfileName: destination.profileName,
            destinationFolderPath: destination.folderPath,
            targetDeviceID: source.deviceID
        )
        presentToast("Queued move — confirm on your Mac")
        deck.removeAll { $0.id == item.id }
    }

    private func performSave(
        _ item: RandomCardItem,
        title: String,
        url: String,
        deviceID: String,
        to destination: BookmarkMoveDestination
    ) {
        let finalTitle = title.isEmpty ? (URL(string: url)?.host ?? url) : title
        SyncConsumer.shared.sendAddBookmark(
            title: finalTitle,
            url: url,
            destinationBrowserName: destination.browserName,
            destinationProfileName: destination.profileName,
            destinationFolderPath: destination.folderPath,
            targetDeviceID: deviceID
        )
        let deviceName = localCache.state.devices.first { $0.id == deviceID }?.name ?? "your Mac"
        presentToast("Save queued for \(deviceName)")
        deck.removeAll { $0.id == item.id }
    }

    private func presentToast(_ message: String) {
        toast = message
    }

    private func reshuffle() {
        var pool = buildPool()
        pool.shuffle()
        deck = Array(pool.prefix(Self.maxDeckSize))
    }

    private func buildPool() -> [RandomCardItem] {
        var items: [RandomCardItem] = []

        for blob in localCache.state.bookmarkBlobs {
            let source = BookmarkSource(deviceID: blob.deviceID, browserName: blob.browserName, profileName: blob.profileName)
            for bookmark in blob.bookmarks {
                guard let url = URL(string: bookmark.url), url.scheme?.hasPrefix("http") == true else { continue }
                let id = "bookmark|\(source.blobID)#\(bookmark.id)"
                guard !skipStore.isSkipped(id) else { continue }
                items.append(RandomCardItem(
                    id: id,
                    title: bookmark.title.isEmpty ? (url.host ?? bookmark.url) : bookmark.title,
                    url: url,
                    source: .bookmark(item: bookmark, source: source)
                ))
            }
        }

        for tab in localCache.state.tabs {
            guard let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true else { continue }
            let id = "tab|\(tab.id)"
            guard !skipStore.isSkipped(id) else { continue }
            items.append(RandomCardItem(
                id: id,
                title: tab.title.isEmpty ? (url.host ?? tab.url) : tab.title,
                url: url,
                source: .openTab(tab: tab)
            ))
        }

        return items
    }
}

/// One swipeable card. Only the top card of the deck reacts to drag gestures;
/// the rest are visible purely for the stacked-deck depth effect.
private struct RandomCardView: View {
    let item: RandomCardItem
    let isTop: Bool
    let cardSize: CGSize
    let isExpanding: Bool
    let onTap: () -> Void
    let onDecision: (RandomCardDecision) -> Void
    let onMenuAction: (RandomCardMenuAction) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var preview: LinkPreview?

    private static let swipeThreshold: CGFloat = 120
    private static let stampFadeDistance: CGFloat = 80

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: isExpanding ? 0 : DS.Radius.xl, style: .continuous)
                .fill(
                    // Text-only tweets sit on the always-dark deck color so the white snippet reads.
                    (preview?.isTweet == true && preview?.image == nil)
                        ? DS.Palette.deckTop
                        : DS.Palette.surfaceMuted
                )

            if let preview, let image = preview.image {
                LinkCardImageView(image: image, preview: preview, compact: false)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
            } else if let preview, preview.isTweet, let snippet = preview.snippetText, !snippet.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    HStack(spacing: DS.Space.sm) {
                        LinkCardAvatarView(preview: preview, diameter: 32, glyphColor: .white)
                        VStack(alignment: .leading, spacing: 1) {
                            if let name = preview.authorName, !name.isEmpty {
                                Text(name)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                            if let handle = preview.authorHandle {
                                Text(handle)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Text(snippet)
                        .font(DS.Font.body)
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(DS.Space.xl)
                .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
            } else {
                Image(systemName: "link")
                    .font(.system(size: DS.IconSize.hero))
                    .foregroundColor(.secondary)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(item.source.badgeText)
                    .font(DS.Font.tag)
                    .padding(.horizontal, DS.Space.sm)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.xs, style: .continuous))
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(item.url.host ?? item.url.absoluteString)
                    .font(DS.Font.meta)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(DS.Space.xl)
            .opacity(isExpanding ? 0 : 1)

            if !isExpanding {
                stampOverlay
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: isExpanding ? 0 : DS.Radius.xl, style: .continuous))
        .rotationEffect(.degrees((isTop && !isExpanding) ? Double(dragOffset.width / 20) : 0))
        .offset((isTop && !isExpanding) ? dragOffset : .zero)
        .gesture((isTop && !isExpanding) ? dragGesture : nil)
        .contextMenu {
            if isTop && !isExpanding {
                menuContent
            }
        }
        .task(id: item.id) {
            preview = await LinkPreviewLoader.shared.preview(for: item.url)
        }
    }

    /// Delete/move for a writable bookmark, close for an open tab. Empty for
    /// a Safari-sourced bookmark — nothing to offer, same as `BookmarkNodeRow`
    /// leaving its own swipe actions off a read-only row.
    @ViewBuilder
    private var menuContent: some View {
        Button {
            onMenuAction(.openInReader)
        } label: {
            Label("Open in Reader", systemImage: "doc.plaintext")
        }

        Link(destination: item.url) {
            Label("Open in Safari", systemImage: "safari")
        }

        ShareLink(item: item.url) {
            Label("Share Link", systemImage: "square.and.arrow.up")
        }

        Button {
            onMenuAction(.copyURL)
        } label: {
            Label("Copy URL", systemImage: "doc.on.doc")
        }

        switch item.source {
        case .bookmark:
            if item.source.isWritableBookmark {
                Button {
                    onMenuAction(.moveBookmark)
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
                Button(role: .destructive) {
                    onMenuAction(.deleteBookmark)
                } label: {
                    Label("Delete Bookmark", systemImage: "trash")
                }
            }
        case .openTab:
            Button {
                onMenuAction(.moveBookmark)
            } label: {
                Label("Save to Folder", systemImage: "folder")
            }
            Button {
                onMenuAction(.openOnMac)
            } label: {
                Label("Open on Mac", systemImage: "laptopcomputer")
            }
            Button(role: .destructive) {
                onMenuAction(.closeTab)
            } label: {
                Label("Close Tab on Mac", systemImage: "xmark.circle")
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isExpanding else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isExpanding else { return }
                let totalTranslation = hypot(value.translation.width, value.translation.height)
                if totalTranslation < 10 {
                    onTap()
                    withAnimation(.spring()) {
                        dragOffset = .zero
                    }
                    return
                }

                if value.translation.width > Self.swipeThreshold {
                    animateOff(direction: 1, decision: .moveTo)
                } else if value.translation.width < -Self.swipeThreshold {
                    animateOff(direction: -1, decision: .skip)
                } else {
                    withAnimation(.spring()) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func animateOff(direction: CGFloat, decision: RandomCardDecision) {
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: direction * 600, height: dragOffset.height)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            onDecision(decision)
            if case .moveTo = decision {
                try? await Task.sleep(for: .milliseconds(200))
                dragOffset = .zero
            }
        }
    }

    @ViewBuilder
    private var stampOverlay: some View {
        if dragOffset.width > 40 {
            stampLabel("MOVE TO", color: DS.Tint.action)
                .opacity(min(1, (dragOffset.width - 40) / Self.stampFadeDistance))
                .rotationEffect(.degrees(-15))
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if dragOffset.width < -40 {
            stampLabel("SKIP", color: DS.Tint.destructive)
                .opacity(min(1, (-dragOffset.width - 40) / Self.stampFadeDistance))
                .rotationEffect(.degrees(15))
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func stampLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.title.bold())
            .foregroundColor(color)
            .padding(.horizontal, DS.Space.md)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous).stroke(color, lineWidth: 3))
    }
}
