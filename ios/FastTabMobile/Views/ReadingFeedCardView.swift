import SwiftUI
import UIKit
import FastTabSync

public struct ReadingFeedCardView: View {
    public let title: String
    public let url: URL
    public let domain: String
    public let badgeText: String
    public let badgeTint: Color
    public let subtitle: String?
    public let fixedWidth: CGFloat?
    /// Reading scroll progress [0.0 – 1.0]. When > 0, shows a thin progress bar at the bottom.
    public let readingProgress: Double
    public let deleteTitle: String
    public let deleteIcon: String
    public let onSelect: () -> Void
    public let onOpenOnMac: (() -> Void)?
    public let onSaveToBookmarks: (() -> Void)?
    public let onDelete: (() -> Void)?

    @State private var preview: LinkPreview?
    @State private var isLoadingPreview: Bool = true

    public static let cardBackgroundColor = Color(uiColor: UIColor { traitCollection in
        if traitCollection.userInterfaceStyle == .dark {
            // Subtle warm dark charcoal card surface in dark mode (low contrast, elevated gently above the deep black app background)
            return UIColor(red: 0.095, green: 0.090, blue: 0.086, alpha: 1.0)
        } else {
            // Crisp white card surface in light mode
            return UIColor.white
        }
    })

    /// A bit darker of the warm grey background, used for chips and thumbnail placeholders.
    public static let warmMutedFillColor = Color(uiColor: UIColor { traitCollection in
        if traitCollection.userInterfaceStyle == .dark {
            // Subtle warm dark fill in dark mode
            return UIColor(red: 0.135, green: 0.128, blue: 0.122, alpha: 1.0)
        } else {
            // A bit darker of the warm grey background in light mode
            return UIColor(red: 0.890, green: 0.880, blue: 0.870, alpha: 1.0)
        }
    })

    public init(
        title: String,
        url: URL,
        domain: String,
        badgeText: String,
        badgeTint: Color = .blue,
        subtitle: String? = nil,
        fixedWidth: CGFloat? = 310,
        readingProgress: Double = 0.0,
        deleteTitle: String = "Delete Link",
        deleteIcon: String = "trash",
        onSelect: @escaping () -> Void,
        onOpenOnMac: (() -> Void)? = nil,
        onSaveToBookmarks: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.title = title
        self.url = url
        self.domain = domain
        self.badgeText = badgeText
        self.badgeTint = badgeTint
        self.subtitle = subtitle
        self.fixedWidth = fixedWidth
        self.readingProgress = readingProgress
        self.deleteTitle = deleteTitle
        self.deleteIcon = deleteIcon
        self.onSelect = onSelect
        self.onOpenOnMac = onOpenOnMac
        self.onSaveToBookmarks = onSaveToBookmarks
        self.onDelete = onDelete
    }

    public var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect()
        } label: {
            HStack(spacing: 8) {
                // Left: Full-height thumbnail without fade effect
                thumbnailView
                    .frame(width: 96, height: 88)
                    .clipped()

                // Right: Title, URL, Folder Badge Chip (each on separate line)
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(displaySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !badgeText.isEmpty {
                        Text(badgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(badgeTint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badgeTint.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 8)
                .padding(.trailing, 12)

                Spacer(minLength: 0)
            }
            .background(Self.cardBackgroundColor)
            // Reading progress bar — thin strip at the bottom of the card
            .overlay(alignment: .bottom) {
                if readingProgress > 0.01 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.6))
                            .frame(width: geo.size.width * readingProgress, height: 3)
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: fixedWidth, height: 88)
        .contextMenu {
            Button {
                onSelect()
            } label: {
                Label("Read Article", systemImage: "newspaper")
            }

            Link(destination: url) {
                Label("Open in Safari", systemImage: "safari")
            }

            if let onOpenOnMac {
                Button {
                    onOpenOnMac()
                } label: {
                    Label("Open on Mac", systemImage: "laptopcomputer")
                }
            }

            if let onSaveToBookmarks {
                Button {
                    onSaveToBookmarks()
                } label: {
                    Label("Save to Bookmarks", systemImage: "bookmark.badge.plus")
                }
            }

            ShareLink(item: url) {
                Label("Share Link", systemImage: "square.and.arrow.up")
            }

            Button {
                UIPasteboard.general.url = url
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }

            if let onDelete {
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(deleteTitle, systemImage: deleteIcon)
                }
            }
        }
        .task(id: url) {
            isLoadingPreview = true
            preview = await LinkPreviewLoader.shared.preview(for: url)
            isLoadingPreview = false
        }
    }

    private var displayTitle: String {
        if !title.isEmpty && !title.hasPrefix("http://") && !title.hasPrefix("https://") {
            return title
        }
        if let previewTitle = preview?.title, !previewTitle.isEmpty {
            return previewTitle
        }
        return title
    }

    private var displaySubtitle: String {
        if let preview, preview.isTweet {
            if let handle = preview.authorHandle, let name = preview.authorName {
                return "\(name) (\(handle))"
            } else if let handle = preview.authorHandle {
                return handle
            }
        }
        return domain
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let image = preview?.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else if let preview, preview.isTweet, let snippet = preview.snippetText, !snippet.isEmpty {
            tweetThumbnailView(preview: preview, snippet: snippet)
        } else {
            ZStack {
                Self.warmMutedFillColor

                if isLoadingPreview {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.plaintext")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary.opacity(0.8))
                        if !domain.isEmpty {
                            Text(domain.prefix(1).uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func tweetThumbnailView(preview: LinkPreview, snippet: String) -> some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)
                    : UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
            })

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("𝕏")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.primary)

                    if let handle = preview.authorHandle {
                        Text(handle)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(snippet)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1.5)
            }
            .padding(7)
        }
    }
}
