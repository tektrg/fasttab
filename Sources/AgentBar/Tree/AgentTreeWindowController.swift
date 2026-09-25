import AppKit
import SwiftUI

/// Owns the Agent Hierarchy window: an `NSWindow` hosting `AgentTreeView`. Same shape as
/// `SettingsWindowController` — its own top-level window, reused (not recreated) across shows;
/// closing it only hides it.
@MainActor
final class AgentTreeWindowController {
    private var window: NSWindow?
    private let model: AgentTreeModel

    init(model: AgentTreeModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // An accessory app is never frontmost by itself; without this the window opens behind
        // whatever app the user is in (same reasoning as `SettingsWindowController.show()`).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AgentTreeView.width, height: AgentTreeView.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Hierarchy"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: AgentTreeView(model: model))
        window.center()
        return window
    }
}
