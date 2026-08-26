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
    case open
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
}

public struct RandomLinksView: View {
    @ObservedObject private var localCache = LocalCache.shared
    @ObservedObject private var skipStore = RandomFeedSkipStore.shared

    @State private var deck: [RandomCardItem] = []
    @State private var hasBuiltInitialDeck = false
    @State private var selectedURLForReader: URL?
    @State private var moveRequest: RandomCardItem?
    @State private var toastMessage: String?
    @State private var showToast = false

    private static let maxDeckSize = 40
    private static let visibleCardCount = 3

    public init() {}

    public var body: some View {
        VStack {
            if deck.isEmpty {
                emptyState
            } else {
                deckStack
                    .padding(20)
            }
        }
        .navigationTitle("Random")
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
        .fullScreenCover(item: $selectedURLForReader) { url in
            InAppBrowserView(url: url)
                .ignoresSafeArea()
        }
        .sheet(item: $moveRequest) { item in
            if case .bookmark(let bookmark, let source) = item.source {
                BookmarkMovePicker(
                    sourceDeviceID: source.deviceID,
                    folderMoveExclusion: FolderMoveExclusion(
                        path: BookmarkTreeBuilder.splitPath(bookmark.folderPath ?? ""),
                        profileKeys: ["\(source.browserName)|\(source.profileName)"],
                        includeSubpaths: false
                    )
                ) { destination in
                    performMove(item, bookmark: bookmark, source: source, to: destination)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showToast, let toastMessage {
                Text(toastMessage)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var deckStack: some View {
        GeometryReader { geometry in
            let cardSize = Self.cardSize(fitting: geometry.size)
            ZStack {
                ForEach(Array(deck.prefix(Self.visibleCardCount).enumerated()).reversed(), id: \.element.id) { index, item in
                    RandomCardView(item: item, isTop: index == 0, cardSize: cardSize, onDecision: { decision in
                        handle(decision, for: item)
                    }, onMenuAction: { action in
                        handleMenuAction(action, for: item)
                    })
                    .scaleEffect(1 - CGFloat(index) * 0.04)
                    .offset(y: CGFloat(index) * 10)
                    .allowsHitTesting(index == 0)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
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
        VStack(spacing: 16) {
            Image(systemName: hasAnySourceData ? "checkmark.circle" : "shuffle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            if hasAnySourceData {
                Text("You've been through today's picks")
                    .font(.headline)
                Text("Skipped links come back tomorrow — or right now.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Shuffle again") {
                    skipStore.resetToday()
                    reshuffle()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Nothing to shuffle yet")
                    .font(.headline)
                Text("Bookmarks and open tabs from your Mac will show up here once they sync.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handle(_ decision: RandomCardDecision, for item: RandomCardItem) {
        switch decision {
        case .open:
            selectedURLForReader = item.url
        case .skip:
            skipStore.skip(item.id)
        }
        deck.removeAll { $0.id == item.id }
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
    let onDecision: (RandomCardDecision) -> Void
    let onMenuAction: (RandomCardMenuAction) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var preview: LinkPreview?

    private static let swipeThreshold: CGFloat = 120
    private static let stampFadeDistance: CGFloat = 80

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(uiColor: .secondarySystemBackground))

            if let image = preview?.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
            } else {
                Image(systemName: "link")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(item.source.badgeText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial)
                    .cornerRadius(6)
                Text(item.title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(item.url.host ?? item.url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(20)

            stampOverlay
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .rotationEffect(.degrees(isTop ? Double(dragOffset.width / 20) : 0))
        .offset(isTop ? dragOffset : .zero)
        .gesture(isTop ? dragGesture : nil)
        .contextMenu {
            if isTop {
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
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                if value.translation.width > Self.swipeThreshold {
                    animateOff(direction: 1, decision: .open)
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
        }
    }

    @ViewBuilder
    private var stampOverlay: some View {
        if dragOffset.width > 40 {
            stampLabel("OPEN", color: .green)
                .opacity(min(1, (dragOffset.width - 40) / Self.stampFadeDistance))
                .rotationEffect(.degrees(-15))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if dragOffset.width < -40 {
            stampLabel("SKIP", color: .red)
                .opacity(min(1, (-dragOffset.width - 40) / Self.stampFadeDistance))
                .rotationEffect(.degrees(15))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func stampLabel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.title.bold())
            .foregroundColor(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 3))
    }
}
