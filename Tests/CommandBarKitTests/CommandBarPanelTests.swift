import AppKit
import Testing
@testable import CommandBarKit

@MainActor
private final class DismissRecorder {
    var location: NSPoint?
    var dismissCount = 0
}

@MainActor
struct CommandBarPanelTests {
    private func makePanel() -> CommandBarPanel {
        _ = NSApplication.shared
        return CommandBarPanel(
            contentRect: NSRect(x: 100, y: 200, width: 640, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    private func mouseDown(at locationInWindow: NSPoint, in panel: NSPanel) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test func commandBarPanelIsNotMovableAndNotMovableByBackground() {
        let panel = makePanel()

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
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.level == .statusBar)
    }

    @Test func mouseDownAcceptedByShouldDismissClickCallsOnDismissWithScreenLocation() {
        let panel = makePanel()
        let recorder = DismissRecorder()
        panel.shouldDismissClick = { location in
            recorder.location = location
            return true
        }
        panel.onDismiss = { recorder.dismissCount += 1 }

        panel.sendEvent(mouseDown(at: NSPoint(x: 10, y: 20), in: panel))

        #expect(recorder.dismissCount == 1)
        #expect(recorder.location == NSPoint(x: 110, y: 220))
    }

    @Test func mouseDownRejectedByShouldDismissClickDoesNotDismiss() {
        let panel = makePanel()
        let recorder = DismissRecorder()
        panel.shouldDismissClick = { _ in false }
        panel.onDismiss = { recorder.dismissCount += 1 }

        panel.sendEvent(mouseDown(at: NSPoint(x: 10, y: 20), in: panel))

        #expect(recorder.dismissCount == 0)
    }

    @Test func fitCanvasUsesInjectedCanvasFrameWithoutMenuBarConstraint() {
        let panel = makePanel()
        var receivedDisplayFrame: CGRect?
        let canvas = CGRect(x: -50, y: -50, width: 5000, height: 4000)

        panel.fitCommandBarCanvasToVisibleScreen(preferMouseScreen: false) { displayFrame in
            receivedDisplayFrame = displayFrame
            return canvas
        }

        #expect(receivedDisplayFrame != nil)
        #expect(panel.frame == canvas)
    }
}
