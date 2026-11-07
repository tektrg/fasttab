import Foundation
import CoreGraphics
import ImageIO

/// Shrinks a browser's favicon bytes (PNG, ICO, JPEG…) into the small PNG the
/// phone needs. ImageIO only, so it builds on both macOS and iOS.
public enum FaviconImage {
    /// A PNG whose longest edge is at most `SyncedFavicons.iconEdgePixels` and
    /// whose size is at most `maxBytes`, trying smaller edges before giving up.
    /// Never enlarges. Nil for undecodable data or an icon that cannot fit.
    public static func compactPNG(
        from data: Data,
        maxBytes: Int = SyncedFavicons.maxIconBytes
    ) -> Data? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let index = largestImageIndex(in: source) else { return nil }

        for edge in [SyncedFavicons.iconEdgePixels, 32, 24] {
            guard let png = thumbnailPNG(source: source, index: index, maxEdge: edge) else { continue }
            if png.count <= maxBytes { return png }
        }
        return nil
    }

    /// `.ico` files hold several sizes; pick the biggest as the source.
    private static func largestImageIndex(in source: CGImageSource) -> Int? {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var best: (index: Int, edge: Int)?
        for i in 0..<count {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0 else { continue }
            let edge = max(w, h)
            if best == nil || edge > best!.edge { best = (i, edge) }
        }
        return best?.index
    }

    private static func thumbnailPNG(source: CGImageSource, index: Int, maxEdge: Int) -> Data? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let target = min(maxEdge, max(w, h))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
