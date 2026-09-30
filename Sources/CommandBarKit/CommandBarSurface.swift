import IndieEdgeRevealUI
import SwiftUI

public struct CommandBarSurface<Content: View>: View {
    /// Which screen edge the bar hugs — determines the outer shape below
    /// (flat on that side, rounded on the rest). See `EdgeRevealSurfaceShape` (IndieEdgeRevealUI).
    var anchor: CommandBarAnchor
    /// The host app's "Background" appearance setting. Also handed down to
    /// every `CommandBarSurfaceBackground` inside `content` through
    /// `EnvironmentValues.commandBarOuterPanelEnabled`.
    var outerPanelEnabled: Bool
    @ViewBuilder var content: Content

    public init(
        anchor: CommandBarAnchor,
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

        // Black, forced-dark, edge-hugging shape with its flares: the shared IndieEdgeRevealUI surface.
        return AnyView(
            EdgeRevealSurface(
                hug: anchor.surfaceHug,
                cornerRadius: CommandBarLayout.surfaceCornerRadius,
                joinRadius: CommandBarLayout.surfaceJoinRadius
            ) {
                content.environment(\.commandBarOuterPanelEnabled, true)
            }
        )
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
