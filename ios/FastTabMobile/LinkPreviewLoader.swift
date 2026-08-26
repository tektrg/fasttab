import Foundation
import LinkPresentation
import UIKit

public struct LinkPreview: Sendable {
    public let title: String?
    public let image: UIImage?
}

/// Fetches an Open Graph-style preview (title + image) for a URL via the
/// system `LinkPresentation` framework — the same mechanism Messages/Safari
/// use for rich link previews, so no bespoke HTML parsing is needed here.
///
/// `LPMetadataProvider` instances are single-use, so a fresh one is created
/// per fetch. Results are cached in memory, and concurrent requests for the
/// same URL (e.g. the top few cards of the deck loading at once) share one
/// in-flight fetch instead of hitting the network twice.
@MainActor
public final class LinkPreviewLoader {
    public static let shared = LinkPreviewLoader()

    /// Maximum cached previews before the oldest entry is evicted.
    /// Each preview can hold a UIImage of several MB, so this bounds
    /// total memory to a reasonable ceiling (~50 images).
    private static let maxCacheEntries = 50

    private var cache: [String: LinkPreview] = [:]
    /// Insertion-order keys for LRU eviction. Newest entries are appended;
    /// oldest entries are removed from the front when the cap is exceeded.
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<LinkPreview, Never>] = [:]

    public init() {}

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
            let provider = LPMetadataProvider()
            let metadata = try? await provider.startFetchingMetadata(for: url)
            let image = await Self.loadImage(from: metadata?.imageProvider)
            return LinkPreview(title: metadata?.title, image: image)
        }
        inFlight[key] = task

        let result = await task.value
        insertIntoCache(key: key, preview: result)
        inFlight[key] = nil
        return result
    }

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

    private static func loadImage(from itemProvider: NSItemProvider?) async -> UIImage? {
        guard let itemProvider, itemProvider.canLoadObject(ofClass: UIImage.self) else { return nil }
        return await withCheckedContinuation { continuation in
            itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }
}
