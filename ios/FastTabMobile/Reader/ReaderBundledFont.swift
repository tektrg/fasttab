import CoreText
import Foundation
import UIKit

/// Fraunces, the reader's one bundled font (heading option, `ReaderHeadingFont.fraunces`).
///
/// - Files: `Resources/Fonts/fraunces-{latin,vietnamese}.woff2` — Google Fonts' latin and
///   vietnamese subsets of the variable font (weight 100–900, optical size 9–144; default
///   instance is 900, so every use sets the weight). Together they cover every Vietnamese
///   letter; each `@font-face` carries Google's `unicode-range`, so WebKit picks the file
///   per character. Other scripts fall back to Georgia (next in the stack).
/// - Licence: SIL OFL 1.1, shipped beside them as `Resources/Fonts/Fraunces-OFL.txt`.
/// - Loading: the reader page uses the article's own https URL as its base, so it can't
///   reach `file://` bundle URLs; the fonts go into the page as `data:` URLs instead
///   (works offline, no URL scheme handler). `@font-face` is lazy: unused, it isn't decoded.
enum ReaderBundledFont {
    struct Subset {
        let resource: String
        /// Google Fonts CSS API `unicode-range` for this subset (fonts.googleapis.com/css2, Fraunces v38).
        let unicodeRange: String
    }

    static let latin = Subset(
        resource: "fraunces-latin",
        unicodeRange: "U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+0304, U+0308, "
            + "U+0329, U+2000-206F, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD")
    static let vietnamese = Subset(
        resource: "fraunces-vietnamese",
        unicodeRange: "U+0102-0103, U+0110-0111, U+0128-0129, U+0168-0169, U+01A0-01A1, U+01AF-01B0, "
            + "U+0300-0301, U+0303-0304, U+0308-0309, U+0323, U+0329, U+1EA0-1EF9, U+20AB")
    static let subsets = [latin, vietnamese]

    /// OpenType `wght` axis tag as a number (CoreText variation dictionary key).
    static let weightAxisTag = 0x7767_6874
    /// `opsz` (optical size, 9–144). WebKit sets it from the text size; native previews must too.
    static let opticalSizeAxisTag = 0x6F70_737A

    static func data(_ subset: Subset) -> Data? {
        Bundle.main.url(forResource: subset.resource, withExtension: "woff2").flatMap { try? Data(contentsOf: $0) }
    }

    /// `@font-face` rules for the reader page (one per subset present in the bundle); nil only
    /// if none is (headings then fall back to Georgia, the next name in the stack).
    static let fontFaceCSS: String? = {
        let faces = subsets.compactMap { subset in
            data(subset).map {
                "@font-face{font-family:'Fraunces';src:url(data:font/woff2;base64,\($0.base64EncodedString())) format('woff2');"
                    + "font-weight:100 900;font-style:normal;font-display:block;unicode-range:\(subset.unicodeRange);}"
            }
        }
        return faces.isEmpty ? nil : faces.joined()
    }()

    /// Decoded once (woff2 decompression); preview rows ask for it on every redraw.
    private static let descriptors: [CTFontDescriptor] = subsets.compactMap { subset in
        data(subset).flatMap { (CTFontManagerCreateFontDescriptorsFromData($0 as CFData) as? [CTFontDescriptor])?.first }
    }

    /// Native Fraunces for SwiftUI (settings preview, Summary headings); CoreText reads woff2
    /// directly. The vietnamese subset rides in the cascade list so Vietnamese text stays Fraunces.
    static func frauncesUIFont(size: CGFloat, weight: Double = 400) -> UIFont? {
        let opticalSize = min(max(Double(size), 9), 144)
        let variation = [kCTFontVariationAttribute: [weightAxisTag: weight, opticalSizeAxisTag: opticalSize]] as CFDictionary
        let varied = descriptors.map { CTFontDescriptorCreateCopyWithAttributes($0, variation) }
        guard let primary = varied.first else { return nil }
        let withCascade = CTFontDescriptorCreateCopyWithAttributes(
            primary, [kCTFontCascadeListAttribute: Array(varied.dropFirst())] as CFDictionary)
        return CTFontCreateWithFontDescriptor(withCascade, size, nil) as UIFont
    }
}
