import AppKit
import SwiftUI
import Testing
@testable import FastTab

/// Renders the Settings window (sidebar + page) on chosen pages, light and
/// dark, to PNGs. A tool, not a check: runs only when `SETTINGS_RENDER_OUT`
/// is set (`scripts/render-settings.sh`). Glass/vibrancy backgrounds don't
/// draw offscreen, so a plain window colour stands in behind the content.
@MainActor
struct SettingsWindowRenderSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["SETTINGS_RENDER_OUT"]

    @Test(.enabled(if: SettingsWindowRenderSheet.outDir != nil))
    func renderSettings() throws {
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = CustomViewStore.shared
        let saved = store.views
        saved.forEach { store.delete(id: $0.id) }
        defer { saved.forEach { store.add($0) } }
        for dark in [false, true] {
            try Self.render(tab: .views, dark: dark, to: out.appendingPathComponent("settings-views-empty-\(dark ? "dark" : "light").png"))
        }
        let samples = [
            CustomView(name: "Reading list", iconName: "book", types: [.tab, .bookmark], keywords: "article"),
            CustomView(name: "Work docs", iconName: "briefcase", types: [.tab], domains: ["docs.google.com", "notion.so"]),
            CustomView(name: "Pinned tabs", iconName: "pin", types: [.tab], pinned: .only),
        ]
        samples.forEach { store.add($0) }
        defer { samples.forEach { store.delete(id: $0.id) } }
        for dark in [false, true] {
            try Self.render(tab: .views, dark: dark, to: out.appendingPathComponent("settings-views-list-\(dark ? "dark" : "light").png"))
        }
    }

    static func render(tab: SettingsTab, dark: Bool, to url: URL) throws {
        SettingsNavigator.shared.requestedTab = tab
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // No AppState/LicenseService: their `shared` start CloudKit, which traps
        // in a test process. The Views page doesn't read them.
        let host = NSHostingView(rootView: SettingsView())
        host.appearance = appearance
        let size = CGSize(width: 680, height: 420)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let frameView = try #require(window.contentView?.superview)
        let bounds = frameView.bounds
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: bounds))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        frameView.cacheDisplay(in: bounds, to: rep)
        // The sidebar's glass container draws as an opaque white slab
        // offscreen; draw the sidebar's own content over it instead.
        if let column = Self.firstView(in: frameView, where: { String(describing: type(of: $0)).contains("SidebarStyleContext") }),
           let sidebar = Self.firstView(in: column, where: { $0 is NSOutlineView }) {
            (sidebar as? NSOutlineView)?.enumerateAvailableRowViews { row, _ in row.layoutSubtreeIfNeeded() }
            let column = sidebar.enclosingScrollView ?? sidebar
            let visible = column.convert(column.bounds, to: frameView)
            let r = sidebar.convert(sidebar.visibleRect, to: frameView)
            let sideRep = try #require(sidebar.bitmapImageRepForCachingDisplay(in: sidebar.visibleRect))
            sidebar.cacheDisplay(in: sidebar.visibleRect, to: sideRep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            appearance?.performAsCurrentDrawingAppearance {
                NSColor.underPageBackgroundColor.setFill()
                NSRect(x: 0, y: 0, width: visible.maxX, height: bounds.height).fill()
            }
            sideRep.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        window.isReleasedWhenClosed = false
        window.close()
    }

    static func firstView(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(view) { return view }
        for sub in view.subviews { if let hit = firstView(in: sub, where: match) { return hit } }
        return nil
    }
}
