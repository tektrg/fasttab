import AppKit
import IndieSettings
import SwiftUI

/// Owns the Settings window: an `NSWindow` hosting `SettingsView`. Used instead
/// of SwiftUI's `Settings` scene because a menu-bar-less accessory app has no
/// menu to open that scene from, and this way the window can be brought to the
/// front explicitly. Closing it only hides it; the window (and its selected
/// tab) is reused next time.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let makeContent: (SettingsNavigator) -> SettingsView
    /// Lets `show(_:)` switch the (reused) window to a given pane.
    private let navigator = SettingsNavigator()

    init(makeContent: @escaping (SettingsNavigator) -> SettingsView) {
        self.makeContent = makeContent
    }

    /// Shows the window; with a tab, switches to that pane (else keeps the last one shown).
    func show(_ tab: SettingsTab? = nil) {
        if let tab { navigator.request(tab) }
        let window = window ?? makeWindow()
        self.window = window
        // An accessory app is never frontmost by itself; without this the
        // window would open behind whatever app the user is in.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: SettingsView.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentBar Settings"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: makeContent(navigator))
        window.center()
        return window
    }
}
