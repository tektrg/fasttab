import Foundation
import IndieLinks
import LinkPresentation
import UIKit

/// Fetches the preview a link card shows.
///
/// Sites the shared `IndieLinks` module recognizes (X, YouTube, Reddit, GitHub) get
/// site-tailored metadata from their free public sources, cached on disk for a week
/// (`LinkCardMetadataCache`). Everything else — and a recognized site whose sources all
/// fail — goes through the system `LinkPresentation` framework, the same mechanism
/// Messages/Safari use for rich link previews.
///
/// Results are cached in memory, and concurrent requests for the same URL (e.g. the top
/// few cards of the deck loading at once) share one in-flight fetch.
@MainActor
public final class LinkPreviewLoader {
    public static let shared = LinkPreviewLoader()

    /// Maximum cached previews before the oldest entry is evicted. Each preview can hold
    /// an image (site images are downsampled to `LinkCardImageLoader.cardMaxPixelSize`),
    /// so this bounds total memory.
    private static let maxCacheEntries = 50

    private var cache: [String: LinkPreview] = [:]
    /// Insertion-order keys for LRU eviction. Newest entries are appended;
    /// oldest entries are removed from the front when the cap is exceeded.
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<LinkPreview, Never>] = [:]

    public init() {}

    /// Whether the URL is an X / Twitter post (status or article), which cards render as a post.
    public static func isXPostURL(_ url: URL) -> Bool {
        LinkSiteDetector.match(url)?.site == .x
    }

    public func preview(for url: URL) async -> LinkPreview {
        let key = url.absoluteString
        if let cached = cache[key] {
            // Promote to most-recently-used
            if let idx = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: idx)
                cacheOrder.append(key)
            }
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<LinkPreview, Never> {
            if let match = LinkSiteDetector.match(url),
               let sitePreview = await Self.fetchSitePreview(for: url, match: match) {
                return sitePreview
            }
            return await Self.fetchStandardPreview(for: url)
        }
        inFlight[key] = task

        let result = await task.value
        insertIntoCache(key: key, preview: result)
        inFlight[key] = nil
        return result
    }

    // MARK: - Recognized sites (IndieLinks)

    private nonisolated static func fetchSitePreview(for url: URL, match: LinkSiteMatch) async -> LinkPreview? {
        let metadataCache = LinkCardMetadataCache.shared
        let cached = metadataCache.lookup(url)
        var metadata = cached?.metadata
        if cached == nil || cached?.isRetryDue == true {
            // On the one retry, a failed or thinner result never replaces what the partial card had.
            let fresh = await LinkSiteResolver().resolve(match)
            if let card = LinkCardRetryPolicy.card(afterRetry: fresh, earlier: cached?.metadata) {
                metadata = card
                metadataCache.store(card, for: url, wasRetry: cached != nil)
            }
        }
        guard let metadata else { return nil }

        let isShort = if case .youtubeVideo(_, let isShort) = match.target { isShort } else { false }
        let crop: LinkCardImageLoader.Crop = metadata.site != .youtube ? .none : (isShort ? .portrait : .widescreen)
        async let image = LinkCardImageLoader.image(
            from: metadata.imageURL, maxPixelSize: LinkCardImageLoader.cardMaxPixelSize, crop: crop
        )
        // The avatar only shows on an X post's text tile, i.e. when there is no media image.
        async let avatar = LinkCardImageLoader.image(
            from: metadata.usesAvatarAsPicture ? metadata.avatarURL : nil,
            maxPixelSize: LinkCardImageLoader.avatarMaxPixelSize
        )
        return LinkPreview(metadata: metadata, image: await image, avatar: await avatar, isYouTubeShort: isShort)
    }

    // MARK: - Generic sites (LinkPresentation)

    private static func fetchStandardPreview(for url: URL) async -> LinkPreview {
        let provider = LPMetadataProvider()
        let metadata = try? await provider.startFetchingMetadata(for: url)
        let image = await Self.loadImage(from: metadata?.imageProvider)
        return LinkPreview(title: metadata?.title, image: image)
    }

    private static func loadImage(from itemProvider: NSItemProvider?) async -> UIImage? {
        guard let itemProvider, itemProvider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    // MARK: - Memory cache

    private func insertIntoCache(key: String, preview: LinkPreview) {
        cache[key] = preview
        // Remove any existing entry to prevent duplicate keys in the order
        // array, which would desynchronize eviction from the dictionary.
        if let idx = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: idx)
        }
        cacheOrder.append(key)
        while cacheOrder.count > Self.maxCacheEntries {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}
