import Foundation
import IndieLinks
import UIKit

/// What a link card shows: title, image and, for sites IndieLinks recognizes (X, YouTube,
/// Reddit, GitHub), the site-tailored extras (author, media kind, avatar, counts).
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
    public let stats: [String: Int]
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
        stats: [String: Int] = [:],
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
        self.stats = stats
        self.isYouTubeShort = isYouTubeShort
        self.siteSubtitle = siteSubtitle
    }

    /// Maps shared L1 metadata to card text, per site:
    /// - X: tweet text (or X Article title) / "Name (@handle)"
    /// - YouTube: video title / channel name
    /// - Reddit: post title / "r/sub · u/author"
    /// - GitHub: "owner/repo" / "★ 1.2k · description"; issue or PR: "owner/repo#N" / its title
    public init(metadata: LinkCardMetadata, image: UIImage? = nil, avatar: UIImage? = nil, isYouTubeShort: Bool = false) {
        let text = Self.cardText(for: metadata)
        self.init(
            title: text.title,
            image: image,
            authorName: metadata.authorName,
            authorHandle: metadata.authorHandle,
            snippetText: metadata.snippet,
            site: metadata.site,
            mediaKind: metadata.mediaKind,
            durationSeconds: metadata.durationSeconds,
            avatar: avatar,
            stats: metadata.stats,
            isYouTubeShort: isYouTubeShort,
            siteSubtitle: text.subtitle
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

    // MARK: - Per-site text

    private static func cardText(for metadata: LinkCardMetadata) -> (title: String?, subtitle: String?) {
        switch metadata.site {
        case .x:
            let title = metadata.title ?? metadata.snippet ?? metadata.authorName.map { "Post by \($0)" }
            let byline: String? = switch (metadata.authorName, metadata.authorHandle) {
            case let (name?, handle?): "\(name) (\(handle))"
            case let (name, handle): name ?? handle
            }
            return (title, byline)
        case .youtube:
            return (metadata.title, metadata.authorName ?? metadata.authorHandle)
        case .reddit:
            return (metadata.title, joined([metadata.authorHandle, metadata.authorName], separator: " · "))
        case .github:
            return gitHubText(for: metadata)
        }
    }

    /// GitHub puts "owner/repo#N" in `authorHandle` only for issue / PR / discussion links.
    private static func gitHubText(for metadata: LinkCardMetadata) -> (title: String?, subtitle: String?) {
        if let numberedPath = metadata.authorHandle, numberedPath.contains("#") {
            return (numberedPath, metadata.title)
        }
        let stars = metadata.stats["stars"].map { "★ \(compactCount($0))" }
        return (metadata.title, joined([stars, metadata.snippet], separator: " · "))
    }

    private static func joined(_ parts: [String?], separator: String) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: separator)
    }

    // MARK: - Formatting

    /// 999 → "999", 1234 → "1.2k", 69_800 → "69.8k", 1_200_000 → "1.2M".
    public static func compactCount(_ count: Int) -> String {
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let value = (Double(count) / divisor * 10).rounded(.down) / 10
            let text = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            return text + suffix
        }
        if count >= 1_000_000 { return scaled(1_000_000, "M") }
        if count >= 1_000 { return scaled(1_000, "k") }
        return String(count)
    }

    /// 45 → "0:45", 75 → "1:15", 3725 → "1:02:05".
    public static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
