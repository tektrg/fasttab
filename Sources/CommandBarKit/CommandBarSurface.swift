import SwiftUI

public struct CommandBarSurface<Content: View>: View {
    /// Which screen edge the bar hugs — determines the outer shape below
    /// (flat on that side, rounded on the rest). See `CommandBarSurfaceShape`.
    var anchor: EdgeRevealStyle
    /// The host app's "Background" appearance setting. Also handed down to
    /// every `CommandBarSurfaceBackground` inside `content` through
    /// `EnvironmentValues.commandBarOuterPanelEnabled`.
    var outerPanelEnabled: Bool
    @ViewBuilder var content: Content

    public init(
        anchor: EdgeRevealStyle,
        outerPanelEnabled: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.anchor = anchor
        self.outerPanelEnabled = outerPanelEnabled
        self.content = content()
    }

    public var body: some View {
        // When the user enables Background, the whole bar gets one shape. Inner
        // sections then render a faint zone fill instead of their own
        // background (CommandBarSurfaceBackground reads the same setting).
        //
        // Pure black in both light and dark mode, and a plain fill rather than
        // `.glassEffect`: the bar reaches under the notch, so it has to match
        // the notch's own black to read as one shape — a theme-aware material
        // would leave a visible seam, and Liquid Glass adds a rim highlight
        // that read as an outline around the whole bar.
        guard outerPanelEnabled else {
            return AnyView(content.environment(\.commandBarOuterPanelEnabled, false))
        }

        // Forced dark so labels, pills, and section fills stay light against
        // the black panel — in light mode they resolve to near-black otherwise.
        return AnyView(
            content
                .environment(\.commandBarOuterPanelEnabled, true)
                .environment(\.colorScheme, .dark)
                .background(
                    CommandBarSurfaceShape(anchor: anchor)
                        .fill(Color.black)
                        // The silhouette flares out past the bar's own width
                        // where it meets the screen edge; negative padding is
                        // what gives the shape room to draw that flare instead
                        // of having it clipped at the content's bounds.
                        .padding(-CommandBarLayout.surfaceJoinRadius)
                )
        )
    }
}

/// The bar's outer silhouette: flat against the screen edge it hugs, softly
/// rounded on the far side, and joined to that edge the way the MacBook notch is
/// joined to the bezel — with a small outward flare rather than a hard right
/// angle, so the bar reads as moulded into the edge it grew out of.
///
/// The path is authored once for a top-hugging bar and mirrored for the side
/// anchors. The silhouette is symmetric along its edge, so mirroring across the
/// diagonal is indistinguishable from rotating it and needs no trigonometry.
///
/// `rect` is the bar's bounds outset by `surfaceJoinRadius` on every side (the
/// caller's negative padding); the bar itself is that rect inset back again,
/// and the flare spans the difference.
public struct CommandBarSurfaceShape: Shape {
    var anchor: EdgeRevealStyle

    public init(anchor: EdgeRevealStyle) {
        self.anchor = anchor
    }

    public func path(in rect: CGRect) -> Path {
        let flareRoom = CommandBarLayout.surfaceJoinRadius
        let surface = rect.insetBy(dx: flareRoom, dy: flareRoom)
        guard surface.width > 0, surface.height > 0 else { return Path() }

        // Extent along the hugged edge, and depth away from it.
        let sideways = CommandBarLayout.isCompact(anchor)
        let along = sideways ? surface.height : surface.width
        let depth = sideways ? surface.width : surface.height

        let local = topHuggingPath(along: along, depth: depth, flareRoom: flareRoom)
        let oriented: Path
        switch anchor {
        case .off, .notch:
            oriented = local
        case .leftEdge:
            // (x, y) -> (y, x): the hugged edge becomes the leading edge.
            oriented = local.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        case .rightEdge:
            // (x, y) -> (depth - y, x): the hugged edge becomes the trailing edge.
            oriented = local.applying(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: depth, ty: 0))
        }
        return oriented.applying(CGAffineTransform(translationX: surface.minX, y: surface.minY))
    }

    /// The silhouette with its hugged edge along `y == 0`, running `along` wide
    /// and `depth` deep.
    private func topHuggingPath(along: CGFloat, depth: CGFloat, flareRoom: CGFloat) -> Path {
        let far = min(CommandBarLayout.surfaceCornerRadius, along / 2, depth / 2)
        let flare = min(flareRoom, depth / 2, along / 4)

        var path = Path()
        // Start out past the bar's own width, level with the screen edge.
        path.move(to: CGPoint(x: -flare, y: 0))
        // Control point sits on the corner the two edges would otherwise have
        // met at, which is exactly where their tangents cross: the curve leaves
        // the screen edge horizontally and rejoins the side vertically, so
        // there is no visible break at either end of the flare.
        path.addQuadCurve(to: CGPoint(x: 0, y: flare), control: .zero)
        path.addLine(to: CGPoint(x: 0, y: depth - far))
        path.addArc(
            tangent1End: CGPoint(x: 0, y: depth),
            tangent2End: CGPoint(x: far, y: depth),
            radius: far
        )
        path.addLine(to: CGPoint(x: along - far, y: depth))
        path.addArc(
            tangent1End: CGPoint(x: along, y: depth),
            tangent2End: CGPoint(x: along, y: depth - far),
            radius: far
        )
        path.addLine(to: CGPoint(x: along, y: flare))
        path.addQuadCurve(
            to: CGPoint(x: along + flare, y: 0),
            control: CGPoint(x: along, y: 0)
        )
        path.closeSubpath()
        return path
    }
}

/// Background for a single command-bar section.
///
/// Behaviour depends on the outer Background preference, read from
/// `EnvironmentValues.commandBarOuterPanelEnabled` (set by `CommandBarSurface`):
/// - Background ON  → faint zone fill; the outer wrap supplies the real background.
/// - Background OFF, macOS 26 → per-section Liquid Glass (default look).
/// - Background OFF, macOS 14 → `.thinMaterial` over opaque base (no glass at all).
public struct CommandBarSurfaceBackground: View {
    var cornerRadius: CGFloat
    var accent: Color = .clear

    @Environment(\.commandBarOuterPanelEnabled) private var outerPanelEnabled

    private static let zoneFillOpacity: Double = 0.05

    public init(cornerRadius: CGFloat, accent: Color = .clear) {
        self.cornerRadius = cornerRadius
        self.accent = accent
    }

    public var body: some View {
        if outerPanelEnabled {
            zoneFillBackground
        } else if #available(macOS 26.0, *) {
            liquidGlassBackground
        } else {
            materialFallbackBackground
        }
    }

    @available(macOS 26.0, *)
    private var liquidGlassBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let glass: Glass = accent == .clear ? .regular : .regular.tint(accent)
        return Color.clear.glassEffect(glass, in: shape)
    }

    // Faint fill used when the outer wrap supplies the real background.
    private var zoneFillBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(Color.primary.opacity(Self.zoneFillOpacity))
            .overlay(shape.fill(accent))
    }

    private var materialFallbackBackground: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return shape
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(shape.fill(.thinMaterial))
            .overlay(shape.fill(accent))
    }
}

public extension View {
    /// Prominent call-to-action styling: Liquid Glass on macOS 26+, bordered
    /// prominent on older systems. Keeps CTA styling consistent in one place.
    @ViewBuilder
    func commandBarProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// Whether the enclosing `CommandBarSurface` draws the single outer panel
/// (sections then use a faint zone fill). Defaults to `true`, matching the
/// host app's default "Background" setting.
private struct CommandBarOuterPanelEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

/// True when the command bar is rendering at the narrow, half-width
/// edge-anchored size — content should wrap rather than truncate.
private struct IsCompactCommandBarKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var commandBarOuterPanelEnabled: Bool {
        get { self[CommandBarOuterPanelEnabledKey.self] }
        set { self[CommandBarOuterPanelEnabledKey.self] = newValue }
    }

    var isCompactCommandBar: Bool {
        get { self[IsCompactCommandBarKey.self] }
        set { self[IsCompactCommandBarKey.self] = newValue }
    }
}
