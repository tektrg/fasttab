import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Black-on-white QR code for a URL, so it scans in dark mode too.
/// Renders nothing if CoreImage can't encode the URL.
struct OnboardingQRCodeView: View {
    let url: URL

    var body: some View {
        if let image = Self.qrImage(for: url) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white))
                .accessibilityLabel("QR code to download FastTab for iPhone")
        }
    }

    static func qrImage(for url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
