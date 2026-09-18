import AppKit

public extension NSScreen {
    /// The screen whose frame contains `point`, treating the outer edge as
    /// inclusive. Plain `frame.contains` follows AppKit's half-open
    /// convention (`minY...<maxY`), which excludes a point sitting exactly on
    /// the top/right boundary — exactly where the cursor parks when hovering
    /// a screen-edge hot zone, since it's clamped against the display's
    /// physical edge. Without this, hovering the notch zone on a display
    /// whose top edge lands on a whole pixel (any external monitor) made the
    /// lookup fall through to `NSScreen.main` for that exact sample, flipping
    /// the trigger zone to the wrong display for an instant and resetting the
    /// hover dwell before it could complete.
    static func containing(_ point: CGPoint) -> NSScreen? {
        screens.first { screen in
            let frame = screen.frame
            return point.x >= frame.minX && point.x <= frame.maxX
                && point.y >= frame.minY && point.y <= frame.maxY
        }
    }
}
