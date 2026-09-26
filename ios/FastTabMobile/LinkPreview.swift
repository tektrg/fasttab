import Foundation
import IndieLinks
import UIKit

/// What a link card shows: title, image and, for sites IndieLinks recognizes (X, YouTube,
/// Reddit, GitHub), the site-tailored extras (author, media kind, avatar).
/// Generic sites come from LinkPresentation and leave `site` nil.
public struct LinkPreview: Sendable {
    public let title: String?
    public let image: UIImage?
    public let authorName: String?
    public let authorHandle: String?
    public let snippetText: String?
    public let site: LinkSite?
    public let mediaKind: LinkMediaKind
    public let durationSeconds: Double?
    /// Author avatar. Loaded only when the card falls back to a text tile (X post without media).
    public let avatar: UIImage?
    public let isYouTubeShort: Bool
    /// The card's second line for a recognized site; nil means "show the domain".
    public let siteSubtitle: String?

    public var isTweet: Bool { site == .x }

    public init(
        title: String? = nil,
        image: UIImage? = nil,
        authorName: String? = nil,
        authorHandle: String? = nil,
        snippetText: String? = nil,
        site: LinkSite? = nil,
        mediaKind: LinkMediaKind = .none,
        durationSeconds: Double? = nil,
        avatar: UIImage? = nil,
        isYouTubeShort: Bool = false,
        siteSubtitle: String? = nil
    ) {
        self.title = title
        self.image = image
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.snippetText = snippetText
        self.site = site
        self.mediaKind = mediaKind
        self.durationSeconds = durationSeconds
        self.avatar = avatar
        self.isYouTubeShort = isYouTubeShort
        self.siteSubtitle = siteSubtitle
    }

    /// Maps shared L1 metadata to card text. Headline and source line come from IndieLinks
    /// (`LinkCardMetadata.headline` / `.secondaryLine`), so Fast Tab and Parklet read the same.
    public init(metadata: LinkCardMetadata, image: UIImage? = nil, avatar: UIImage? = nil, isYouTubeShort: Bool = false) {
        self.init(
            title: metadata.headline ?? metadata.authorName.map { "Post by \($0)" },
            image: image,
            authorName: metadata.authorName,
            authorHandle: metadata.authorHandle,
            snippetText: metadata.snippet,
            site: metadata.site,
            mediaKind: metadata.mediaKind,
            durationSeconds: metadata.durationSeconds,
            avatar: avatar,
            isYouTubeShort: isYouTubeShort,
            siteSubtitle: metadata.secondaryLine
        )
    }

    /// The title a card displays. A recognized site's own title wins (the stored title is
    /// usually the browser tab's, e.g. `Name on X: "…" / X`); otherwise the stored title,
    /// unless it is only a URL.
    public static func cardTitle(storedTitle: String, preview: LinkPreview?) -> String {
        if preview?.site != nil, let siteTitle = preview?.title, !siteTitle.isEmpty { return siteTitle }
        let storedIsURL = storedTitle.hasPrefix("http://") || storedTitle.hasPrefix("https://")
        if !storedTitle.isEmpty && !storedIsURL { return storedTitle }
        if let previewTitle = preview?.title, !previewTitle.isEmpty { return previewTitle }
        return storedTitle
    }
}
