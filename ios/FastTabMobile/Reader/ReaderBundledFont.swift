import CoreText
import Foundation
import UIKit

/// Fraunces, the reader's one bundled font (heading option, `ReaderHeadingFont.fraunces`).
///
/// - File: `Resources/Fonts/fraunces-latin.woff2` — Google Fonts' latin subset of the
///   variable font (weight 100–900, optical size 9–144; default instance is 900, so every
///   use sets the weight). Latin only: Vietnamese letters outside it (ă đ ơ ư, most
///   stacked tones) fall back to Georgia glyph by glyph.
/// - Licence: SIL OFL 1.1, shipped beside it as `Resources/Fonts/Fraunces-OFL.txt`.
/// - Loading: the reader page uses the article's own https URL as its base, so it can't
///   reach `file://` bundle URLs; the font goes into the page as a `data:` URL instead
///   (works offline, no URL scheme handler). `@font-face` is lazy: unused, it isn't decoded.
enum ReaderBundledFont {
    static let frauncesResource = "fraunces-latin"
    /// OpenType `wght` axis tag as a number (CoreText variation dictionary key).
    static let weightAxisTag = 0x7767_6874
    /// `opsz` (optical size, 9–144). WebKit sets it from the text size; native previews must too.
    static let opticalSizeAxisTag = 0x6F70_737A

    static let frauncesData: Data? = {
        guard let url = Bundle.main.url(forResource: frauncesResource, withExtension: "woff2") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }()

    /// `@font-face` rule for the reader page; nil only if the font is missing from the bundle
    /// (headings then fall back to Georgia, the next name in the stack).
    static let fontFaceCSS: String? = frauncesData.map {
        "@font-face{font-family:'Fraunces';src:url(data:font/woff2;base64,\($0.base64EncodedString())) format('woff2');"
            + "font-weight:100 900;font-style:normal;font-display:block;}"
    }

    /// Decoded once (woff2 decompression); preview rows ask for it on every redraw.
    private static let frauncesDescriptor: CTFontDescriptor? = frauncesData.flatMap {
        (CTFontManagerCreateFontDescriptorsFromData($0 as CFData) as? [CTFontDescriptor])?.first
    }

    /// Native Fraunces for SwiftUI previews (CoreText reads woff2 directly).
    static func frauncesUIFont(size: CGFloat, weight: Double = 400) -> UIFont? {
        guard let base = frauncesDescriptor else { return nil }
        let opticalSize = min(max(Double(size), 9), 144)
        let attributes = [kCTFontVariationAttribute: [weightAxisTag: weight, opticalSizeAxisTag: opticalSize]] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil) as UIFont
    }
}
