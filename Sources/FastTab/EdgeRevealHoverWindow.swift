import AppKit

/// Invisible, click-through window that reports when the cursor crosses its
/// frame. Backs the notch/edge hover trigger (see `EdgeRevealService`)
/// without a permanently-running global mouse-moved monitor: `NSTrackingArea`
/// enter/exit events are delivered by the window server on demand, so there's
/// no per-pixel dispatch cost while the cursor is elsewhere on screen, and no
/// need to disable macOS's idle sleep to keep detection alive in the
/// background.
///
/// `ignoresMouseEvents = true` lets every click still reach whatever's
/// underneath (the real menu bar, or app content under the edge band) —
/// verified empirically that `NSTrackingArea` enter/exit still fire on such a
/// window; that's not documented and easy to get backwards.
final class EdgeRevealHoverWindow: NSWindow {
    private let trackingView: HoverTrackingView

    init(zoneFrame: CGRect, onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        trackingView = HoverTrackingView(frame: NSRect(origin: .zero, size: zoneFrame.size))
        trackingView.onEnter = onEnter
        trackingView.onExit = onExit

        super.init(contentRect: zoneFrame, styleMask: .borderless, backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        // Above regular app windows and full-screen Spaces (mirrors what the
        // global monitor used to see regardless of what else was on screen),
        // while `ignoresMouseEvents` keeps it invisible to clicks.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        contentView = trackingView
        setFrame(zoneFrame, display: false)
    }
}

private final class HoverTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            // `.activeAlways` so this fires whether or not our (never-key)
            // window or app is active — the whole point is detecting hover
            // while some other app is frontmost.
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
