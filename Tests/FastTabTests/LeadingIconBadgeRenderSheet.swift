import AppKit
import Foundation
import SwiftUI
import Testing
import IndieCommandBar
@testable import FastTab

/// Result rows with the source badge (bookmark / clock) vs the browser logo,
/// light + dark: `scripts/render-leading-badge.sh` → `<dir>/sheet.png`.
/// Env-gated (skipped in a normal `swift test`). Draws the real result row
/// (`SwipeableResultRow`), which search, Recents and custom views all use.
@MainActor
struct LeadingIconBadgeRenderSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["LEADING_BADGE_RENDER_OUT"]
    static let size = CGSize(width: 380, height: 300)

    struct Row: Identifiable {
        let result: BrowserSearchResult
        let favicon: NSImage?
        let selected: Bool
        var id: String { result.id }
    }

    static func favicon(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 32, height: 32), xRadius: 7, yRadius: 7).fill()
        image.unlockFocus()
        return image
    }

    static let rows: [Row] = [
        Row(result: CustomViewFilterTests.item(.tab, "https://a.example/1", title: "Open tab · browser logo"), favicon: favicon(.systemIndigo), selected: false),
        Row(result: CustomViewFilterTests.item(.bookmark, "https://b.example/2", title: "Bookmark · bookmark badge"), favicon: favicon(.systemTeal), selected: false),
        Row(result: CustomViewFilterTests.item(.bookmark, "https://b.example/3", title: "Bookmark · selected"), favicon: favicon(.systemTeal), selected: true),
        Row(result: CustomViewFilterTests.item(.history, "https://c.example/4", title: "History · clock badge", browser: "Safari"), favicon: favicon(.systemPink), selected: false),
        Row(result: CustomViewFilterTests.item(.bookmark, "https://d.example/5", title: "Bookmark · no site icon"), favicon: nil, selected: false),
        Row(result: CustomViewFilterTests.item(.history, "https://e.example/6", title: "$(echo INJECTED)", browser: "Safari"), favicon: nil, selected: false),
    ]

    struct Panel: View {
        let dark: Bool
        var body: some View {
            VStack(spacing: 2) {
                ForEach(LeadingIconBadgeRenderSheet.rows) { row in
                    SwipeableResultRow(
                        result: row.result,
                        isSelected: row.selected,
                        faviconImage: row.favicon,
                        showWindowName: false,
                        showProfileName: false,
                        pointerEdge: nil,
                        pointerOffset: 0,
                        keyboardEdge: nil,
                        isConfirmingRemoval: false,
                        onHoverChange: { _ in }, onSelect: {}, onCopy: {}, onRemove: {}
                    )
                    .padding(.horizontal, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .frame(width: LeadingIconBadgeRenderSheet.size.width, height: LeadingIconBadgeRenderSheet.size.height, alignment: .top)
            .background(dark ? Color(white: 0.11) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    func capture(dark: Bool) async throws -> CGImage {
        let host = NSHostingView(rootView: Panel(dark: dark))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: Self.size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        return try #require(RowRemovalFrameSheet.render(host))
    }

    @Test(.enabled(if: LeadingIconBadgeRenderSheet.outDir != nil))
    func sheet() async throws {
        let outDir = try #require(Self.outDir)
        let panels = [try await capture(dark: true), try await capture(dark: false)]
        let w = Int(Self.size.width), h = Int(Self.size.height), gap = 16
        let image = NSImage(size: NSSize(width: panels.count * (w + gap) + gap, height: h + 2 * gap))
        image.lockFocusFlipped(true)
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        for (i, panel) in panels.enumerated() {
            NSImage(cgImage: panel, size: NSSize(width: w, height: h))
                .draw(in: NSRect(x: gap + i * (w + gap), y: gap, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: try #require(image.tiffRepresentation))
        try #require(rep?.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("sheet.png"))
    }
}
