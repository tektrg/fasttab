import Foundation
import ImageIO
import UIKit

/// Downloads a link-card image and decodes it downsampled, so a feed of cards never holds
/// full-resolution photos in memory. Not main-actor bound: decoding runs off the main thread.
enum LinkCardImageLoader {
    /// Large enough for the full-width Tab Switcher / Random cards, small for the feed thumbnail.
    static let cardMaxPixelSize: CGFloat = 900
    static let avatarMaxPixelSize: CGFloat = 96

    /// YouTube `hqdefault` is 4:3 with black bars: a video fills the middle 16:9 band,
    /// a Short the middle 9:16 column.
    enum Crop: Sendable {
        case none, widescreen, portrait

        var aspectRatio: CGFloat? {
            switch self {
            case .none: nil
            case .widescreen: 16.0 / 9.0
            case .portrait: 9.0 / 16.0
            }
        }
    }

    static func image(from url: URL?, maxPixelSize: CGFloat, crop: Crop = .none) async -> UIImage? {
        guard let url else { return nil }
        let request = URLRequest(url: cardSizedURL(url), timeoutInterval: 8)
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
        else { return nil }
        return decode(body, maxPixelSize: maxPixelSize, crop: crop)
    }

    /// X media URLs from the API ask for `name=orig` (full camera resolution); `medium`
    /// (≤1200 px) is plenty for a card. Other URLs are returned unchanged.
    static func cardSizedURL(_ url: URL) -> URL {
        guard url.host()?.lowercased() == "pbs.twimg.com",
              url.path.hasPrefix("/media/") || url.path.contains("video_thumb"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var queryItems = (components.queryItems ?? []).filter { $0.name != "name" }
        queryItems.append(URLQueryItem(name: "name", value: "medium"))
        components.queryItems = queryItems
        return components.url ?? url
    }

    /// The centered rect of `size` with the given width / height ratio.
    static func centerCropRect(for size: CGSize, aspectRatio: CGFloat) -> CGRect {
        let imageRatio = size.width / size.height
        if imageRatio > aspectRatio {
            let width = (size.height * aspectRatio).rounded()
            return CGRect(x: ((size.width - width) / 2).rounded(), y: 0, width: width, height: size.height)
        }
        let height = (size.width / aspectRatio).rounded()
        return CGRect(x: 0, y: ((size.height - height) / 2).rounded(), width: size.width, height: height)
    }

    private static func decode(_ body: Data, maxPixelSize: CGFloat, crop: Crop) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(body as CFData, nil),
              var cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        if let aspectRatio = crop.aspectRatio {
            let fullSize = CGSize(width: cgImage.width, height: cgImage.height)
            cgImage = cgImage.cropping(to: centerCropRect(for: fullSize, aspectRatio: aspectRatio)) ?? cgImage
        }
        return UIImage(cgImage: cgImage)
    }
}
