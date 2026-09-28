import AppKit
import SwiftUI
import Testing
@testable import FastTab

/// The onboarding window is a fixed 440×520 with the step dots below the step,
/// leaving ~494pt for a step. These pin that the iPhone step fits in both of
/// its states, and that its QR code actually encodes something scannable.
@MainActor
struct OnboardingIPhoneStepTests {
    private static let stepWidth: CGFloat = 440
    private static let stepHeightBudget: CGFloat = 494

    private func fittingHeight(downloadURL: URL?) -> CGFloat {
        let host = NSHostingView(rootView: OnboardingIPhoneStep(downloadURL: downloadURL, onContinue: {})
            .frame(width: Self.stepWidth))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test func comingSoonStateFitsTheStepBudget() {
        let height = fittingHeight(downloadURL: nil)
        #expect(height <= Self.stepHeightBudget, "coming-soon iPhone step is \(height)pt tall")
    }

    @Test func downloadStateFitsTheStepBudget() {
        let height = fittingHeight(downloadURL: URL(string: "https://apps.apple.com/app/id0000000000")!)
        #expect(height <= Self.stepHeightBudget, "download iPhone step is \(height)pt tall")
    }

    @Test func qrCodeIsBlackOnWhite() throws {
        let url = URL(string: "https://apps.apple.com/app/id0000000000")!
        let image = try #require(OnboardingQRCodeView.qrImage(for: url))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        // The generator pads the symbol with a light quiet zone; walking the
        // diagonal inward must then hit the dark top-left finder pattern.
        func gray(_ i: Int) -> CGFloat? { bitmap.colorAt(x: i, y: i)?.usingColorSpace(.deviceGray)?.whiteComponent }
        #expect((gray(0) ?? 0) > 0.9)
        let firstDark = (0..<bitmap.pixelsWide).first { (gray($0) ?? 1) < 0.1 }
        #expect(firstDark != nil)
    }

    @Test func benefitIDsAreUnique() {
        let ids = OnboardingBenefit.iPhoneBenefits.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
