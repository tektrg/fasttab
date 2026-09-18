import AppKit
import Testing
@testable import FastTab

@MainActor
struct CommandBarWindowBehaviorTests {
    @Test func commandBarPanelIsNotMovableAndNotMovableByBackground() {
        _ = NSApplication.shared
        let panel = CommandBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        #expect(!panel.isMovable)
        #expect(!panel.isMovableByWindowBackground)

        // Attempting to set them to true must not change their values
        panel.isMovable = true
        panel.isMovableByWindowBackground = true

        #expect(!panel.isMovable)
        #expect(!panel.isMovableByWindowBackground)
    }

    @Test func configureCommandBarOverlayBehaviorDisablesMovement() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.configureCommandBarOverlayBehavior()

        #expect(!window.isMovable)
        #expect(!window.isMovableByWindowBackground)
        #expect(window.collectionBehavior.contains(.stationary))
    }

    @Test func onboardingWindowIsNotMovable() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        OnboardingWindowController.configureOnboardingWindow(window)

        #expect(!window.isMovable)
        #expect(!window.isMovableByWindowBackground)
    }
}
