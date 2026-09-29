import AppKit
import UniformTypeIdentifiers

/// One image attached to a message draft, already sized for upload. The dashboard stores it and
/// the agent gets its file path in the text (the Claude peer socket drops image blocks — see
/// AGENTS.md "Image attachments").
struct MessageImage: Equatable, Sendable, Identifiable {
    /// Same limits as the dashboard (`image_attachments.py`).
    static let maxCount = 4
    static let maxBytes = 5 * 1024 * 1024
    static let maxLongEdge: CGFloat = 2048
    static let thumbnailEdge: CGFloat = 96

    let id: UUID
    let data: Data
    /// `image/png` or `image/jpeg`.
    let contentType: String
    /// Small PNG for the chip, so the card never decodes the full image on redraw.
    let thumbnail: Data

    /// Downscales to `maxLongEdge`, encodes PNG, falls back to JPEG (lower quality each try) while
    /// over `maxBytes`. Nil when the image can't be read or never gets under the cap.
    static func prepare(_ image: NSImage) -> MessageImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let sized = scaled(cgImage, longEdge: maxLongEdge),
              let thumb = scaled(cgImage, longEdge: thumbnailEdge).flatMap({ encode($0, as: .png) })
        else { return nil }
        if let png = encode(sized, as: .png), png.count <= maxBytes {
            return MessageImage(id: UUID(), data: png, contentType: "image/png", thumbnail: thumb)
        }
        for quality in [0.85, 0.7, 0.5] {
            if let jpeg = encode(sized, as: .jpeg, quality: quality), jpeg.count <= maxBytes {
                return MessageImage(id: UUID(), data: jpeg, contentType: "image/jpeg", thumbnail: thumb)
            }
        }
        return nil
    }

    /// The images a paste or drop carries: image data on the pasteboard, or image files.
    static func images(from pasteboard: NSPasteboard) -> [NSImage] {
        let imageURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        if !imageURLs.isEmpty { return imageURLs.compactMap(NSImage.init(contentsOf:)) }
        // A copied file with no image type must not fall through to its icon (NSImage reads file icons).
        if pasteboard.types?.contains(.fileURL) == true { return [] }
        return (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
    }

    static func pasteboardHasImage(_ pasteboard: NSPasteboard) -> Bool { !images(from: pasteboard).isEmpty }

    private static func scaled(_ image: CGImage, longEdge: CGFloat) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let factor = min(1, longEdge / max(width, height))
        if factor == 1 { return image }
        let size = CGSize(width: max(1, (width * factor).rounded()), height: max(1, (height * factor).rounded()))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, as type: NSBitmapImageRep.FileType, quality: Double = 1) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: type, properties: type == .jpeg ? [.compressionFactor: quality] : [:])
    }
}
