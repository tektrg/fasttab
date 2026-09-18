import AppKit

/// Borderless, non-activating panel that hosts a command bar on a
/// screen-sized transparent canvas. The host decides which clicks fall
/// outside the visible bar (`shouldDismissClick`) and what dismissing means
/// (`onDismiss`); the panel only intercepts the click.
public final class CommandBarPanel: NSPanel {
    /// Whether a mouse-down at this screen location (AppKit, y-up) lands
    /// outside the visible bar and should dismiss it instead of reaching
    /// the content.
    public var shouldDismissClick: (@MainActor @Sendable (NSPoint) -> Bool)?
    /// Called for a mouse-down `shouldDismissClick` accepted; the event is
    /// then swallowed.
    public var onDismiss: (@MainActor @Sendable () -> Void)?

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
    public override var isMovable: Bool {
        get { false }
        set { }
    }
    public override var isMovableByWindowBackground: Bool {
        get { false }
        set { }
    }

    /// AppKit's default behavior pushes any window whose frame reaches into the
    /// menu bar strip back down below it. That silently shrank the full-screen
    /// canvas we set in `fitCommandBarCanvasToVisibleScreen`, leaving a
    /// menu-bar-height gap between the notch-anchored bar and the true top of
    /// the display. Returning the rect unchanged keeps the canvas flush.
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.isMouseDownEvent, let shouldDismissClick {
            let screenLocation = convertPoint(toScreen: event.locationInWindow)

            if shouldDismissClick(screenLocation) {
                onDismiss?()
                return
            }
        }

        super.sendEvent(event)
    }
}

private extension NSEvent {
    var isMouseDownEvent: Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }
}

public extension NSWindow {
    func configureCommandBarOverlayBehavior() {
        styleMask.insert(.nonactivatingPanel)
        // Above the menu bar (`.mainMenu`), not merely `.floating`: the bar now
        // sits flush against the true top of the display, so at `.floating` the
        // menu bar painted over its top strip — invisible with a translucent
        // menu bar, but an opaque band under Reduce Transparency.
        level = .statusBar

        var behavior = collectionBehavior
        behavior.remove(.moveToActiveSpace)
        behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        collectionBehavior = behavior
        isMovable = false
        isMovableByWindowBackground = false
    }

    /// Resizes the window to the canvas `canvasFrame` derives from the
    /// preferred display's full frame.
    func fitCommandBarCanvasToVisibleScreen(
        preferMouseScreen: Bool,
        canvasFrame: (CGRect) -> CGRect
    ) {
        // Full screen frame, not `visibleFrame` — `visibleFrame` excludes the
        // menu bar strip, which left a gap between the notch anchor and the
        // true top edge of the display instead of sitting flush against it.
        let displayFrame = preferredCommandBarDisplay(preferMouseScreen: preferMouseScreen)?.frame ?? NSScreen.main?.frame ?? frame

        setFrame(canvasFrame(displayFrame), display: true, animate: false)
    }

    private func preferredCommandBarDisplay(preferMouseScreen: Bool) -> NSScreen? {
        if preferMouseScreen {
            let mouseLocation = NSEvent.mouseLocation

            if let mouseScreen = NSScreen.containing(mouseLocation) {
                return mouseScreen
            }
        }

        return screen ?? NSScreen.main
    }
}
