import AppKit
import SwiftUI
import Testing
@testable import FastTab

/// The Settings window is a fixed 680×420. A page whose content asks for more
/// height than that makes the split view lay out taller than the window and
/// SwiftUI centres it, so the window shows only an empty middle slice: no
/// sidebar rows, no page content (Settings › Views, 2026-11-10).
@MainActor @Suite(.serialized)
struct SettingsWindowLayoutTests {
    /// Height the whole split view (sidebar + detail) is laid out at.
    static func splitViewHeight(for tab: SettingsTab) throws -> CGFloat {
        SettingsNavigator.shared.requestedTab = tab
        // No AppState/LicenseService: their `shared` start CloudKit, which traps
        // in a test process. The pages checked here don't read them.
        let host = NSHostingView(rootView: SettingsView())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 420),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let split = try #require(host.subviews.first)
        return split.frame.height
    }

    /// Window content height: 420 + the 32pt titlebar (full-size content view).
    static let windowHeight: CGFloat = 452

    @Test func viewsPageFitsTheWindowWithNoViews() throws {
        let store = CustomViewStore.shared
        let saved = store.views
        saved.forEach { store.delete(id: $0.id) }
        defer { saved.forEach { store.add($0) } }
        #expect(try Self.splitViewHeight(for: .views) <= Self.windowHeight)
    }

    @Test func viewsPageFitsTheWindowWithSavedViews() throws {
        let store = CustomViewStore.shared
        let added = (1...12).map { CustomView(name: "Layout check $(echo INJECTED) \($0)", iconName: "star", types: [.tab]) }
        added.forEach { store.add($0) }
        defer { added.forEach { store.delete(id: $0.id) } }
        #expect(try Self.splitViewHeight(for: .views) <= Self.windowHeight)
    }
}
