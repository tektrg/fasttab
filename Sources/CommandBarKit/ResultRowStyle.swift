import SwiftUI

public enum ResultSwipeAction: Equatable, Sendable {
    case delete
    case copy

    public var iconName: String {
        switch self {
        case .delete: return "checkmark"
        case .copy: return "link"
        }
    }

    public var tint: Color {
        switch self {
        case .delete: return .green
        case .copy: return .accentColor
        }
    }

    public var sign: CGFloat {
        switch self {
        case .delete: return -1
        case .copy: return 1
        }
    }
}

public enum ResultSwipeMetrics {
    public static let revealDistance: CGFloat = 74
    public static let confirmDistance: CGFloat = 138
    public static let maximumOffset: CGFloat = 158
    public static let actionIconInset: CGFloat = 8

    /// How far the row's content keeps sliding once removal is confirmed —
    /// well past `maximumOffset`, so the row visibly continues its swipe
    /// motion off to the side rather than snapping back before it collapses.
    /// Clipped by the row's own `clipShape`, so it doesn't need to match the
    /// row's actual width.
    public static let removalExitDistance: CGFloat = 260

    /// Minimal rows are much shorter than Full rows — a full-size 30pt action
    /// icon would overflow the row height, so it scales down with the style.
    public static func actionIconSize(for rowStyle: ResultRowStyle) -> CGFloat {
        rowStyle == .minimal ? 22 : 30
    }
}

/// Result row display density, set in the host app's Settings (`rawValue` is
/// persisted — do not rename without a migration). Full shows every metadata cue
/// (type glyph, recency, pills, URL/path); Minimal shows only the leading
/// icon and title, for fast scanning.
public enum ResultRowStyle: String, CaseIterable, Identifiable, Sendable {
    case full
    case minimal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .full: return "Full"
        case .minimal: return "Minimal"
        }
    }
}
