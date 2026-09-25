import SwiftUI
import UIKit
import FastTabSync

public struct ReadingFeedCardView: View {
    public let title: String
    public let url: URL
    public let domain: String
    public let badgeText: String
    public let badgeTint: Color
    public let badgeIcon: String?
    public let subtitle: String?
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

    /// Thumbnail shape: 16:10, wide enough for video frames, tall enough for article art.
    static let thumbnailAspectRatio: CGFloat = 16.0 / 10.0

    public init(
        title: String,
        url: URL,
        domain: String,
        badgeText: String,
        badgeTint: Color = DS.Tint.action,
        badgeIcon: String? = nil,
        subtitle: String? = nil,
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
        self.badgeIcon = badgeIcon
        self.subtitle = subtitle
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
            // Vertical card: thumbnail on top, text below. Width comes from the parent
            // carousel; the title always reserves two lines so cards in a row line up.
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(Self.thumbnailAspectRatio, contentMode: .fit)
                    .overlay { thumbnailView }
                    .clipped()
                    .overlay(alignment: .bottom) { progressBar }

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(displayTitle)
                        .font(DS.Font.cardTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)

                    Text(displaySubtitle)
                        .font(DS.Font.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !badgeText.isEmpty {
                        DSTag(badgeText, tint: badgeTint, systemImage: badgeIcon)
                            .padding(.top, DS.Space.xxs)
                    }
                }
                .padding(DS.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(DS.Palette.hairline, lineWidth: 1)
            }
            .dsShadow(.card)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
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
        LinkPreview.cardTitle(storedTitle: title, preview: preview)
    }

    private var displaySubtitle: String {
        preview?.siteSubtitle ?? domain
    }

    /// Reading progress: a thin accent strip along the bottom edge of the thumbnail.
    @ViewBuilder
    private var progressBar: some View {
        if readingProgress > 0.01 {
            GeometryReader { geo in
                Rectangle()
                    .fill(DS.Tint.action)
                    .frame(width: geo.size.width * min(readingProgress, 1), height: 3)
            }
            .frame(height: 3)
            .background(Color.black.opacity(0.15))
            .accessibilityLabel("\(Int(readingProgress * 100)) percent read")
        }
    }

    /// Site image (with play / Shorts overlays), else a text tile for an X or Reddit post
    /// without media, else the generic placeholder.
    @ViewBuilder
    private var thumbnailView: some View {
        if let preview, let image = preview.image {
            LinkCardImageView(image: image, preview: preview)
        } else if let preview, preview.site == .x || preview.site == .reddit,
                  let snippet = preview.snippetText, !snippet.isEmpty {
            LinkCardTextTileView(preview: preview, text: snippet)
        } else {
            ZStack {
                DS.Palette.surfaceMuted

                if isLoadingPreview {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    VStack(spacing: DS.Space.xs) {
                        Text(domain.prefix(1).uppercased())
                            .font(.title.weight(.bold))
                            .foregroundStyle(.tertiary)
                        Image(systemName: "doc.plaintext")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityHidden(true)
                }
            }
        }
    }
}
