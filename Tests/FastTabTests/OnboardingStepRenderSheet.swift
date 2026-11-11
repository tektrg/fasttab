import AppKit
import SwiftUI
import Testing
@testable import FastTab

/// Renders the tightest onboarding steps (source picker with nothing on,
/// extension waiting, iPhone download) at the real window size, both layouts,
/// light and dark, onto one contact sheet. A tool, not a check: runs only
/// when `ONBOARDING_RENDER_OUT` is set (`scripts/render-onboarding-steps.sh`).
/// Window glass doesn't draw offscreen, so a plain window colour stands in.
@MainActor
struct OnboardingStepRenderSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["ONBOARDING_RENDER_OUT"]

    @Test(.enabled(if: OnboardingStepRenderSheet.outDir != nil))
    func renderSheet() throws {
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let phones = PairedPhoneStore(defaults: OnboardingStepFit.scratchDefaults())
        let steps: [(String, AnyView)] = [
            ("Sources (none on)", AnyView(SourcePickerStep(store: OnboardingStepFit.sourceStore(enabled: []), onContinue: {}))),
            ("Extension (waiting)", AnyView(ExtensionInstallStep(didAutoAdvance: .constant(true), onContinue: {}, onAutoAdvance: {}))),
            ("iPhone (download)", AnyView(OnboardingIPhoneStep(downloadURL: URL(string: "https://apps.apple.com/app/id0000000000")!, pairedPhoneStore: phones, onContinue: {}))),
        ]
        var tiles: [[NSBitmapImageRep]] = []
        for (_, step) in steps {
            var row: [NSBitmapImageRep] = []
            for layout in OnboardingLayout.all {
                for dark in [false, true] {
                    row.append(try Self.render(step, layout: layout, dark: dark))
                }
            }
            tiles.append(row)
        }
        // Grid: one row per step; columns = regular light/dark, compact light/dark.
        let gap: CGFloat = 24, label: CGFloat = 28
        let colW = tiles[0].map { CGFloat($0.pixelsWide) }
        let rowH = tiles.map { $0.map { CGFloat($0.pixelsHigh) }.max()! }
        let width = colW.reduce(gap, { $0 + $1 + gap })
        let height = rowH.reduce(gap, { $0 + $1 + label + gap }) + label
        let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]
        let headers = OnboardingLayout.all.flatMap { l in ["light", "dark"].map { "\(Int(l.windowSize.width))×\(Int(l.windowSize.height)) \($0)" } }
        var y = height - gap - label
        var x = gap
        for (c, h) in headers.enumerated() { (h as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs); x += colW[c] + gap }
        for (r, row) in tiles.enumerated() {
            y -= label
            (steps[r].0 as NSString).draw(at: NSPoint(x: gap, y: y + 4), withAttributes: attrs)
            y -= rowH[r]
            x = gap
            for (c, tile) in row.enumerated() {
                tile.draw(in: NSRect(x: x, y: y + rowH[r] - CGFloat(tile.pixelsHigh), width: CGFloat(tile.pixelsWide), height: CGFloat(tile.pixelsHigh)))
                x += colW[c] + gap
            }
            y -= gap
        }
        NSGraphicsContext.restoreGraphicsState()
        try #require(sheet.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("sheet.png"))
    }

    /// The step in its fixed slot (`stepHeight`) above a stand-in for the step
    /// dots, at the window's exact size, 1x.
    static func render(_ step: AnyView, layout: OnboardingLayout, dark: Bool) throws -> NSBitmapImageRep {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = VStack(spacing: 0) {
            step
                .environment(\.onboardingHeroScale, layout.heroScale)
                .frame(width: layout.windowSize.width, height: layout.stepHeight)
                .clipped()
            HStack(spacing: 6) { ForEach(0..<7) { _ in Circle().fill(.secondary).frame(width: 6, height: 6) } }
                .frame(height: layout.windowSize.height - layout.stepHeight - layout.stepDotsBottomPadding)
                .padding(.bottom, layout.stepDotsBottomPadding)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height)
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: layout.windowSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        for _ in 0..<15 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let bounds = host.bounds
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance?.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
        NSGraphicsContext.restoreGraphicsState()
        host.cacheDisplay(in: bounds, to: rep)
        return rep
    }
}
