import AppKit
import Testing
@testable import FastTab

@MainActor
struct CommandBarWindowBehaviorTests {
    @Test func onboardingWindowIsNotMovable() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        OnboardingWindowController.configureOnboardingWindow(window, layout: .compact)

        #expect(!window.isMovable)
        #expect(!window.isMovableByWindowBackground)
    }
}
