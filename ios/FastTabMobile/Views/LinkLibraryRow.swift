import SwiftUI
import FastTabSync

/// One saved link in the "View all" screen: thumbnail, title, read progress. The same
/// picture and title rules as the Read tab's cards (`LinkThumbnailContent`,
/// `LinkPreview.cardTitle`), laid out as a list row.
struct LinkLibraryRow<Trailing: View>: View {
    let title: String
    let url: URL?
    let domain: String
    /// Replaces the site line (e.g. the Trash's "deleted for good in 12 days").
    var subtitle: String? = nil
    /// Best-known read progress, 0...1.
    let progress: Double
    var badgeText: String? = nil
    var badgeTint: Color = DS.Tint.action
    var badgeIcon: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    @State private var preview: LinkPreview?
    @State private var isLoadingPreview = true

    private static var thumbnailWidth: CGFloat { 104 }

    var body: some View {
        HStack(spacing: DS.Space.md) {
            Color.clear
                .frame(width: Self.thumbnailWidth)
                .aspectRatio(ReadingFeedCardView.thumbnailAspectRatio, contentMode: .fit)
                .overlay { LinkThumbnailContent(preview: preview, isLoading: isLoadingPreview, domain: domain) }
                .clipped()
                .overlay(alignment: .bottom) { progressBar }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(LinkPreview.cardTitle(storedTitle: title, preview: preview))
                    .font(DS.Font.cardTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle ?? preview?.siteSubtitle ?? domain)
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                progressLabel
                if let badgeText, !badgeText.isEmpty {
                    DSTag(badgeText, tint: badgeTint, systemImage: badgeIcon)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(progressText ?? "")
        .task(id: url) {
            guard let url else {
                isLoadingPreview = false
                return
            }
            isLoadingPreview = true
            preview = await LinkPreviewLoader.shared.preview(for: url)
            isLoadingPreview = false
        }
    }

    /// "Read" once finished, "NN% read" while in progress, nothing before the first scroll.
    private var progressText: String? {
        if LinkShelves.isFinished(progress: progress) { return "Read" }
        return progress > 0.01 ? "\(Int(min(progress, 1) * 100))% read" : nil
    }

    @ViewBuilder
    private var progressLabel: some View {
        if let progressText {
            let finished = LinkShelves.isFinished(progress: progress)
            Label(progressText, systemImage: finished ? "checkmark.circle.fill" : "book")
                .font(DS.Font.meta)
                .foregroundStyle(finished ? DS.Tint.success : DS.Tint.action)
                .labelStyle(.titleAndIcon)
        }
    }

    /// Same thin strip as the cards, along the thumbnail's bottom edge.
    @ViewBuilder
    private var progressBar: some View {
        if progress > 0.01 {
            GeometryReader { geo in
                Rectangle()
                    .fill(DS.Tint.action)
                    .frame(width: geo.size.width * min(progress, 1), height: 3)
            }
            .frame(height: 3)
            .background(Color.black.opacity(0.15))
        }
    }
}

extension LinkLibraryRow where Trailing == EmptyView {
    init(
        title: String, url: URL?, domain: String, subtitle: String? = nil, progress: Double,
        badgeText: String? = nil, badgeTint: Color = DS.Tint.action, badgeIcon: String? = nil
    ) {
        self.init(
            title: title, url: url, domain: domain, subtitle: subtitle, progress: progress,
            badgeText: badgeText, badgeTint: badgeTint, badgeIcon: badgeIcon, trailing: { EmptyView() }
        )
    }
}
