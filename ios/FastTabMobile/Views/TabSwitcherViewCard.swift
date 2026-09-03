import SwiftUI
import FastTabSync

/// A single card in the iOS-style Tab Switcher deck.
///
/// Faithfully mimics the card in iOS Multitasking App Switcher:
/// - Floating header above the card with browser icon badge, title, domain host, and close button
/// - Rounded rectangular preview window with:
///   1. Simulated browser fallback card
///   2. OpenGraph image preview (from `LinkPreviewLoader`)
///   3. Live `WKWebView` webpage rendering (`TabWebPreviewView`) when near active viewport
/// - Bottom status pills (Pinned, Audible, Window)
/// - Swipe-up "CLOSE" stamp indicator when dragged vertically
struct TabSwitcherViewCard: View {
    let tab: SyncedTab
    let cardSize: CGSize
    let isNearActive: Bool
    /// Whether this card is close enough to the active viewport to justify
    /// fetching its OpenGraph preview image. Cards far off-screen skip the
    /// network round-trip entirely and show only the fallback card.
    let shouldLoadPreview: Bool
    let isExpanding: Bool
    let dragOffsetY: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    let onOpenOnMac: () -> Void
    let onSaveBookmark: () -> Void
    let onCopyURL: () -> Void

    @State private var preview: LinkPreview?

    init(
        tab: SyncedTab,
        cardSize: CGSize,
        isNearActive: Bool = true,
        shouldLoadPreview: Bool = true,
        isExpanding: Bool = false,
        dragOffsetY: CGFloat = 0,
        onSelect: @escaping () -> Void,
        onClose: @escaping () -> Void,
        onOpenOnMac: @escaping () -> Void,
        onSaveBookmark: @escaping () -> Void,
        onCopyURL: @escaping () -> Void
    ) {
        self.tab = tab
        self.cardSize = cardSize
        self.isNearActive = isNearActive
        self.shouldLoadPreview = shouldLoadPreview
        self.isExpanding = isExpanding
        self.dragOffsetY = dragOffsetY
        self.onSelect = onSelect
        self.onClose = onClose
        self.onOpenOnMac = onOpenOnMac
        self.onSaveBookmark = onSaveBookmark
        self.onCopyURL = onCopyURL
    }

    private var displayTitle: String {
        if !tab.title.isEmpty { return tab.title }
        if let previewTitle = preview?.title, !previewTitle.isEmpty { return previewTitle }
        return URL(string: tab.url)?.host() ?? tab.url
    }

    private var domainHost: String {
        URL(string: tab.url)?.host() ?? tab.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Floating Header (App Icon + Title + Close Button)
            cardHeader
                .frame(width: cardSize.width)
                .opacity(isExpanding ? 0 : 1)

            // Main Card Body
            cardBody
                .frame(width: cardSize.width, height: cardSize.height)
                .contentShape(RoundedRectangle(cornerRadius: isExpanding ? 0 : 28, style: .continuous))
                .onTapGesture {
                    onSelect()
                }
        }
        .offset(y: dragOffsetY)
        .scaleEffect(dragOffsetY < 0 ? max(0.85, 1.0 + dragOffsetY / 1200) : 1.0)
        .contextMenu {
            contextMenuContent
        }
        .task(id: shouldLoadPreview ? tab.url : nil) {
            guard shouldLoadPreview, let url = URL(string: tab.url) else { return }
            preview = await LinkPreviewLoader.shared.preview(for: url)
        }
    }

    // MARK: - Card Header

    private var cardHeader: some View {
        HStack(spacing: 8) {
            // Browser / App Icon Badge
            browserIconBadge

            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("\(tab.browserName) · \(domainHost)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }

            Spacer(minLength: 4)

            // Direct Close button
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.6), .white.opacity(0.25))
                    .symbolRenderingMode(.palette)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tab")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
        .shadow(color: Color.black.opacity(0.7), radius: 10, x: 0, y: 4)
    }

    private var browserIconBadge: some View {
        let (iconName, tintColor) = browserIconData(for: tab.browserName)
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tintColor.gradient)
                .frame(width: 24, height: 24)
                .shadow(color: tintColor.opacity(0.4), radius: 4, y: 2)

            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    // MARK: - Card Body

    private var cardBody: some View {
        ZStack(alignment: .bottom) {
            // 1. Base fallback simulated browser page
            fallbackCardContent

            // 2. OpenGraph preview image if loaded
            if let image = preview?.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardSize.width, height: cardSize.height)
                    .clipped()
            }

            // 3. Live WKWebView preview — only instantiated when the card is
            //    within ±1 of the active index. Each WKWebView spins up a
            //    separate WebContent process (~20-50 MB), so this caps the
            //    total to 3 instances instead of one per HTTP tab.
            if isNearActive, let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true {
                TabWebPreviewView(url: url, isVisible: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }

            // 4. Bottom Gradient & Metadata Overlay
            bottomGradientOverlay
                .opacity(isExpanding ? 0 : 1)

            // 5. Swipe Up Close Stamp / Indicator
            if dragOffsetY < -20 && !isExpanding {
                closeSwipeIndicator
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: isExpanding ? 0 : 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isExpanding ? 0 : 28, style: .continuous)
                .strokeBorder(isExpanding ? Color.clear : Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: isExpanding ? Color.clear : Color.black.opacity(0.35), radius: isExpanding ? 0 : 18, x: 0, y: isExpanding ? 0 : 8)
    }

    // MARK: - Fallback Content

    private var fallbackCardContent: some View {
        VStack(spacing: 16) {
            // Simulated Address Bar
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.75))
                Text(domainHost)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.10))
            .clipShape(Capsule())
            .padding(.top, 16)

            Spacer()

            // Large Center Icon
            let (iconName, tintColor) = browserIconData(for: tab.browserName)
            ZStack {
                Circle()
                    .fill(tintColor.opacity(0.18))
                    .frame(width: 72, height: 72)

                Image(systemName: iconName)
                    .font(.system(size: 32))
                    .foregroundStyle(tintColor)
            }

            Text(displayTitle)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.14, blue: 0.20),
                    Color(red: 0.08, green: 0.10, blue: 0.15),
                    Color(red: 0.05, green: 0.07, blue: 0.10)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Bottom Overlay

    private var bottomGradientOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()

            HStack(spacing: 6) {
                if tab.isPinned {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }

                if tab.isAudible {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.purple.opacity(0.85))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }

                if let windowName = tab.windowName, !windowName.isEmpty {
                    Text(windowName)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }

                Spacer()
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.75)],
                startPoint: .center,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Swipe Indicator

    private var closeSwipeIndicator: some View {
        let progress = min(1.0, abs(dragOffsetY) / 110.0)
        return VStack {
            HStack(spacing: 6) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                Text("CLOSE")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.red.opacity(0.85 + 0.15 * progress))
            .clipShape(Capsule())
            .shadow(color: .red.opacity(0.4), radius: 8, y: 3)
            .padding(.top, 20)
            .opacity(Double(progress))
            .scaleEffect(0.8 + 0.2 * progress)

            Spacer()
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            onSelect()
        } label: {
            Label("Open in Reader", systemImage: "doc.plaintext")
        }

        if let url = URL(string: tab.url) {
            Link(destination: url) {
                Label("Open in Safari", systemImage: "safari")
            }

            ShareLink(item: url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }
        }

        Button {
            onOpenOnMac()
        } label: {
            Label("Open on Mac", systemImage: "laptopcomputer")
        }

        Button {
            onCopyURL()
        } label: {
            Label("Copy URL", systemImage: "doc.on.doc")
        }

        Button {
            onSaveBookmark()
        } label: {
            Label("Save to Folder", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            onClose()
        } label: {
            Label("Close Tab on Mac", systemImage: "xmark.circle")
        }
    }

    // MARK: - Browser Icon Helper

    private func browserIconData(for browserName: String) -> (systemName: String, color: Color) {
        let name = browserName.lowercased()
        if name.contains("safari") {
            return ("safari.fill", .blue)
        } else if name.contains("chrome") {
            return ("globe.americas.fill", .green)
        } else if name.contains("arc") {
            return ("circle.hexagongrid.fill", .purple)
        } else if name.contains("firefox") {
            return ("flame.fill", .orange)
        } else if name.contains("edge") {
            return ("e.circle.fill", .teal)
        } else if name.contains("brave") {
            return ("shield.fill", .orange)
        } else if name.contains("orion") {
            return ("star.circle.fill", .indigo)
        } else {
            return ("globe", .blue)
        }
    }
}
