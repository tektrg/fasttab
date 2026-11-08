import Foundation
import CoreGraphics
import ImageIO

/// Shrinks a browser's favicon bytes (PNG, ICO, JPEG…) into the small PNG the
/// phone needs. ImageIO only, so it builds on both macOS and iOS.
public enum FaviconImage {
    /// Mac: a source image bigger than this on either side is never decoded (a tiny file can
    /// declare gigapixels; decoding it would balloon memory).
    public static let maxSourceEdge = 1024
    /// Phone: icons arrive already shrunk to `SyncedFavicons.iconEdgePixels`; anything
    /// claiming more than this is not ours and is never decoded.
    public static let maxSyncedEdge = 256

    /// Declared pixel size of the first image, from the header only (no decode).
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(source: source, index: 0)
    }

    /// True when `data` is small enough in bytes and declared pixels to decode safely.
    public static func isSafeToDecode(
        _ data: Data,
        maxBytes: Int = SyncedFavicons.maxIconBytes,
        maxEdge: Int = maxSyncedEdge
    ) -> Bool {
        guard !data.isEmpty, data.count <= maxBytes,
              let size = pixelSize(of: data) else { return false }
        return size.width > 0 && size.height > 0 && size.width <= maxEdge && size.height <= maxEdge
    }

    private static func pixelSize(source: CGImageSource, index: Int) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

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
            guard let size = pixelSize(source: source, index: i),
                  size.width > 0, size.height > 0,
                  size.width <= maxSourceEdge, size.height <= maxSourceEdge else { continue }
            let edge = max(size.width, size.height)
            if best == nil || edge > best!.edge { best = (i, edge) }
        }
        return best?.index
    }

    private static func thumbnailPNG(source: CGImageSource, index: Int, maxEdge: Int) -> Data? {
        guard let size = pixelSize(source: source, index: index) else { return nil }
        let target = min(maxEdge, max(size.width, size.height))
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
