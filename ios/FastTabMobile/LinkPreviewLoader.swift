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

    private var cache: [String: LinkPreview] = [:]
    private var inFlight: [String: Task<LinkPreview, Never>] = [:]

    public init() {}

    public func preview(for url: URL) async -> LinkPreview {
        let key = url.absoluteString
        if let cached = cache[key] {
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
        cache[key] = result
        inFlight[key] = nil
        return result
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
