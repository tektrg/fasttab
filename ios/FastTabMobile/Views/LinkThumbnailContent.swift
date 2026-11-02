import SwiftUI

/// The picture for a saved link: the site image (with play / Shorts overlays), else a text
/// tile for an X or Reddit post without media, else a letter placeholder. Shared by the
/// Read tab's cards (`ReadingFeedCardView`) and the "View all" rows (`LinkLibraryRow`).
/// Fills whatever frame the caller gives it.
struct LinkThumbnailContent: View {
    let preview: LinkPreview?
    let isLoading: Bool
    let domain: String

    var body: some View {
        if let preview, let image = preview.image {
            LinkCardImageView(image: image, preview: preview)
        } else if let preview, preview.site == .x || preview.site == .reddit,
                  let snippet = preview.snippetText, !snippet.isEmpty {
            LinkCardTextTileView(preview: preview, text: snippet)
        } else {
            ZStack {
                DS.Palette.surfaceMuted

                if isLoading {
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
