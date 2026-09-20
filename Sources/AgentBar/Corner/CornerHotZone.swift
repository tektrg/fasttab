import CoreGraphics

/// The bottom-right corner of a display, where resting the pointer brings the corner tab in. Pure.
///
/// Only a corner with nothing beyond it counts: where another display sits to the right or
/// below, the pointer crosses the seam on its way somewhere else and must not trigger it.
/// Frames are in AppKit screen coordinates (y up), the same as `NSEvent.mouseLocation`.
enum CornerHotZone {
    /// How close to both edges the pointer must be, in points. The pointer stops at the edge,
    /// so this can be small; a little slack covers scaled displays.
    static let size: CGFloat = 8

    static func contains(_ point: CGPoint, displayFrames: [CGRect]) -> Bool {
        guard let display = displayFrames.first(where: { inclusivelyContains($0, point) }) else { return false }
        let inCorner = point.x >= display.maxX - size && point.y <= display.minY + size
        return inCorner && !hasNeighbour(of: display, beyondCornerAt: point, in: displayFrames)
    }

    private static func inclusivelyContains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    /// Another display touching this one's right edge at the pointer's height, or its bottom edge below it.
    private static func hasNeighbour(of display: CGRect, beyondCornerAt point: CGPoint, in frames: [CGRect]) -> Bool {
        frames.contains { other in
            guard other != display else { return false }
            let onTheRight = other.minX >= display.maxX - 1 && other.minX <= display.maxX + 1
                && point.y >= other.minY && point.y <= other.maxY
            let below = other.maxY >= display.minY - 1 && other.maxY <= display.minY + 1
                && point.x >= other.minX && point.x <= other.maxX
            return onTheRight || below
        }
    }
}
