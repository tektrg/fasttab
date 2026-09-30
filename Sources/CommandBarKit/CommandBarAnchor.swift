import IndieEdgeReveal

/// Which screen edge the command bar hugs: its shape, position and reveal direction.
/// Separate from the hover trigger (`EdgeRevealStyle`, IndieEdgeReveal), which has more
/// spots than the bar has layouts; `init(revealStyle:)` picks the nearest layout.
public enum CommandBarAnchor: CaseIterable, Sendable {
    case notch
    case leftEdge
    case rightEdge

    /// Corners open the bar on their side's edge; the bottom edge (and Off) at the top,
    /// since the bar has no bottom-hugging layout.
    public init(revealStyle: EdgeRevealStyle) {
        switch revealStyle {
        case .leftEdge, .topLeftCorner, .bottomLeftCorner: self = .leftEdge
        case .rightEdge, .topRightCorner, .bottomRightCorner: self = .rightEdge
        case .off, .notch, .bottomEdge: self = .notch
        }
    }
}
