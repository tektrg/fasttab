import AppKit
import SwiftUI
import Testing
import IndieSettings
@testable import AgentBar

/// Renders Agent Bar's Settings window (sidebar + first page) light and dark to PNGs.
/// A tool, not a check: runs only when `AGENTBAR_SETTINGS_RENDER_OUT` is set.
/// Same capture approach as FastTabTests `SettingsWindowRenderSheet`.
@MainActor
struct AgentBarSettingsRenderSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["AGENTBAR_SETTINGS_RENDER_OUT"]

    @Test(.enabled(if: AgentBarSettingsRenderSheet.outDir != nil))
    func renderSettings() throws {
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for tab in [SettingsTab.general, .statusSource] {
            for dark in [false, true] {
                try Self.render(tab: tab, dark: dark, to: out.appendingPathComponent("settings-\(tab.id)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    static func makeView(_ navigator: SettingsNavigator) -> SettingsView {
        SettingsView(
            settings: AgentBarSettings(defaults: makeScratchDefaults("settings-render")),
            actions: AgentBarSettingsActions(changeHotkey: { .applied($0) }, setHotkeyRecording: { _ in }),
            connectionTester: DashboardConnectionTester(),
            navigator: navigator)
    }

    static func render(tab: SettingsTab, dark: Bool, to url: URL) throws {
        let navigator = SettingsNavigator()
        navigator.request(tab)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: makeView(navigator))
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
