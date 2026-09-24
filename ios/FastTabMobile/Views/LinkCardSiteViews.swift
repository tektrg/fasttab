import SwiftUI
import UIKit

// Site-tailored pieces of a link card (X, YouTube, Reddit, GitHub), shared by the reading
// feed card, the Tab Switcher card and the Random deck card so each site looks the same
// everywhere. Generic sites never reach these: their `LinkPreview.site` is nil.

/// The preview image plus its site overlays: a play badge on video, a "Shorts" marker.
/// `compact` is the feed's 96 × 88 thumbnail; the full-size cards pass `false`.
struct LinkCardImageView: View {
    let image: UIImage
    let preview: LinkPreview
    var compact: Bool = true

    /// GitHub's Open Graph card is a 2:1 image of text; cropping it cuts the repo name
    /// mid-word, so it is shown whole on its own white background.
    private var showsWholeImage: Bool { preview.site == .github }

    /// `Color.clear` takes the size the parent offers, so the filled image is cropped to
    /// it and the badges sit inside the visible frame, not the overflowing image.
    var body: some View {
        (showsWholeImage ? Color.white : Color.clear)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: showsWholeImage ? .fit : .fill)
            }
            .clipped()
            .overlay { LinkCardMediaOverlay(preview: preview, compact: compact) }
    }
}

/// Play badge (+ duration when known) for video previews, and the Shorts marker.
struct LinkCardMediaOverlay: View {
    let preview: LinkPreview
    var compact: Bool = true

    var body: some View {
        ZStack {
            if preview.mediaKind == .video {
                if preview.site == .youtube {
                    centeredPlayBadge
                } else {
                    // Full-size cards keep their bottom edge for the title overlay.
                    cornerPlayBadge
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .bottomLeading : .topTrailing)
                        .padding(compact ? 5 : 12)
                }
            }
            if preview.isYouTubeShort {
                Text("Shorts")
                    .font(.system(size: compact ? 8.5 : 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, compact ? 5 : 8)
                    .padding(.vertical, compact ? 2 : 3)
                    .background(Color.red.opacity(0.9), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(compact ? 5 : 12)
            }
        }
    }

    private var centeredPlayBadge: some View {
        let diameter: CGFloat = compact ? 28 : 56
        return Image(systemName: "play.fill")
            .font(.system(size: diameter * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .offset(x: diameter * 0.04)
            .frame(width: diameter, height: diameter)
            .background(Color.black.opacity(0.55), in: Circle())
    }

    private var cornerPlayBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: compact ? 7 : 11, weight: .bold))
            if let seconds = preview.durationSeconds {
                Text(LinkPreview.durationText(seconds))
                    .font(.system(size: compact ? 9 : 13, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, compact ? 2.5 : 4)
        .background(Color.black.opacity(0.6), in: Capsule())
    }
}

/// X author avatar circle; the 𝕏 glyph when no avatar loaded.
struct LinkCardAvatarView: View {
    let preview: LinkPreview
    let diameter: CGFloat
    /// Glyph color when there is no avatar. The dark full-size cards pass white.
    var glyphColor: Color = .primary

    var body: some View {
        if let avatar = preview.avatar {
            Image(uiImage: avatar)
                .resizable()
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        } else {
            Text("𝕏")
                .font(.system(size: diameter * 0.6, weight: .black))
                .foregroundStyle(glyphColor)
                .frame(width: diameter, height: diameter)
        }
    }
}

/// The feed thumbnail for a post with no image: a tinted tile with the author and the
/// post text. X is slate-blue with the author avatar; Reddit is warm orange.
struct LinkCardTextTileView: View {
    let preview: LinkPreview
    let text: String

    static let redditOrange = Color(red: 1.0, green: 0.27, blue: 0.0)

    private var tileBackground: Color {
        let isReddit = preview.site == .reddit
        return Color(uiColor: UIColor { trait in
            switch (isReddit, trait.userInterfaceStyle == .dark) {
            case (true, true): UIColor(red: 0.20, green: 0.11, blue: 0.07, alpha: 1.0)
            case (true, false): UIColor(red: 1.00, green: 0.93, blue: 0.89, alpha: 1.0)
            case (false, true): UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)
            case (false, false): UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
            }
        })
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            tileBackground

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if preview.site == .reddit {
                        Circle()
                            .fill(Self.redditOrange)
                            .frame(width: 8, height: 8)
                    } else {
                        LinkCardAvatarView(preview: preview, diameter: 18)
                    }
                    // X: "@handle". Reddit: "r/sub".
                    if let handle = preview.authorHandle {
                        Text(handle)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(preview.site == .reddit ? Self.redditOrange : .secondary)
                            .lineLimit(1)
                    }
                }

                Text(text)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(preview.site == .reddit ? 5 : 4)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(1.5)
            }
            .padding(7)
        }
    }
}
