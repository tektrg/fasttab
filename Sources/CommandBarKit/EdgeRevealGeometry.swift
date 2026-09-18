import CoreGraphics
import AppKit

/// Where hovering reveals the command bar, and so which screen edge the bar
/// hugs. `rawValue` is persisted by the host app — do not rename without a
/// migration.
public enum EdgeRevealStyle: String, CaseIterable, Identifiable, Sendable {
    case off
    case notch
    case leftEdge
    case rightEdge

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off:       return "Off"
        case .notch:     return "Notch"
        case .leftEdge:  return "Left Edge"
        case .rightEdge: return "Right Edge"
        }
    }
}

/// Pure geometry for the notch/edge hover-reveal trigger. Kept free of
/// `NSScreen` in the calculation functions themselves (`ScreenInfo` carries
/// just the numbers that matter) so the math is unit-testable without a real
/// display attached.
public enum EdgeRevealGeometry {
    /// Size of the fake "virtual notch" pill drawn on displays that have no
    /// physical notch (external monitor as primary, older MacBook, clamshell).
    public static let fallbackNotchSize = CGSize(width: 200, height: 32)

    /// Width of the live hover strip on the left/right edge.
    public static let edgeZoneWidth: CGFloat = 10

    /// Vertical band the left/right edge trigger lives in, as a fraction of
    /// screen height — middle 40%, so it stays clear of the four corners
    /// macOS already reserves for hot corners / Notification Center.
    public static let edgeBandFraction: ClosedRange<CGFloat> = 0.3...0.7

    /// The subset of `NSScreen` state the geometry math depends on.
    public struct ScreenInfo: Equatable, Sendable {
        public let frame: CGRect
        public let safeAreaTopInset: CGFloat
        /// Global-coordinate max-X of the left auxiliary area, i.e. where the
        /// physical notch's left edge begins. `nil` when unavailable (pre-macOS 12
        /// or no notch).
        public let notchLeftAuxMaxX: CGFloat?
        /// Global-coordinate min-X of the right auxiliary area, i.e. where the
        /// physical notch's right edge ends.
        public let notchRightAuxMinX: CGFloat?

        public var hasPhysicalNotch: Bool { safeAreaTopInset > 0 }

        public init(
            frame: CGRect,
            safeAreaTopInset: CGFloat,
            notchLeftAuxMaxX: CGFloat?,
            notchRightAuxMinX: CGFloat?
        ) {
            self.frame = frame
            self.safeAreaTopInset = safeAreaTopInset
            self.notchLeftAuxMaxX = notchLeftAuxMaxX
            self.notchRightAuxMinX = notchRightAuxMinX
        }
    }

    public static func screenInfo(for screen: NSScreen) -> ScreenInfo {
        var leftMaxX: CGFloat?
        var rightMinX: CGFloat?

        if #available(macOS 12.0, *) {
            leftMaxX = screen.auxiliaryTopLeftArea?.maxX
            rightMinX = screen.auxiliaryTopRightArea?.minX
        }

        return ScreenInfo(
            frame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            notchLeftAuxMaxX: leftMaxX,
            notchRightAuxMinX: rightMinX
        )
    }

    /// Rect of the notch (or its fake stand-in), in global screen coordinates.
    public static func notchZone(_ info: ScreenInfo) -> CGRect {
        if info.hasPhysicalNotch,
           let leftMaxX = info.notchLeftAuxMaxX,
           let rightMinX = info.notchRightAuxMinX,
           rightMinX > leftMaxX {
            let width = rightMinX - leftMaxX
            return CGRect(
                x: leftMaxX,
                y: info.frame.maxY - info.safeAreaTopInset,
                width: width,
                height: info.safeAreaTopInset
            )
        }

        let height = info.hasPhysicalNotch ? info.safeAreaTopInset : fallbackNotchSize.height
        return CGRect(
            x: info.frame.midX - fallbackNotchSize.width / 2,
            y: info.frame.maxY - height,
            width: fallbackNotchSize.width,
            height: height
        )
    }

    /// Rect of the live hover strip on the left/right edge, in global screen
    /// coordinates. `style` must be `.leftEdge` or `.rightEdge`.
    public static func edgeBandZone(_ frame: CGRect, style: EdgeRevealStyle) -> CGRect {
        let bandBottom = frame.minY + frame.height * edgeBandFraction.lowerBound
        let bandTop = frame.minY + frame.height * edgeBandFraction.upperBound
        let x = style == .leftEdge ? frame.minX : frame.maxX - edgeZoneWidth

        return CGRect(
            x: x,
            y: bandBottom,
            width: edgeZoneWidth,
            height: bandTop - bandBottom
        )
    }

    /// The live hover zone for a given trigger style, or `nil` when the
    /// trigger is off.
    public static func triggerZone(for style: EdgeRevealStyle, screenInfo info: ScreenInfo) -> CGRect? {
        switch style {
        case .off:
            return nil
        case .notch:
            return notchZone(info)
        case .leftEdge, .rightEdge:
            return edgeBandZone(info.frame, style: style)
        }
    }

    /// Gap between the pill and the screen boundary/notch it hugs.
    public static let pillGap: CGFloat = 2

    /// Size of the hover-reveal preview pill. Notch
    /// pills read left-to-right; edge pills read top-to-bottom, since they
    /// hug the side of the screen rather than the top.
    public static func pillSize(for style: EdgeRevealStyle) -> CGSize {
        switch style {
        case .off:
            return .zero
        case .notch:
            return CGSize(width: 64, height: 22)
        case .leftEdge, .rightEdge:
            return CGSize(width: 22, height: 64)
        }
    }

    /// Where the peek pill sits, anchored against `zone` (the trigger zone
    /// returned by `triggerZone`), in global screen coordinates.
    public static func pillFrame(for style: EdgeRevealStyle, zone: CGRect, screenFrame: CGRect) -> CGRect {
        let size = pillSize(for: style)

        switch style {
        case .off:
            return .zero
        case .notch:
            return CGRect(
                x: zone.midX - size.width / 2,
                y: zone.minY - size.height - pillGap,
                width: size.width,
                height: size.height
            )
        case .leftEdge:
            return CGRect(
                x: screenFrame.minX + pillGap,
                y: zone.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .rightEdge:
            return CGRect(
                x: screenFrame.maxX - size.width - pillGap,
                y: zone.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
    }
}
