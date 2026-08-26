import SwiftUI

struct CommandBarSurface<Content: View>: View {
    /// Which screen edge the bar hugs — determines the outer shape below
    /// (flat on that side, rounded on the rest). See `CommandBarSurfaceShape`.
    var anchor: EdgeRevealStyle
    @ViewBuilder var content: Content
    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = true

    var body: some View {
        // When the user enables Background, the whole bar gets one shape. Inner
        // sections then render a faint zone fill instead of their own
        // background (CommandBarSurfaceBackground reads the same key).
        //
        // Pure black in both light and dark mode, and a plain fill rather than
        // `.glassEffect`: the bar reaches under the notch, so it has to match
        // the notch's own black to read as one shape — a theme-aware material
        // would leave a visible seam, and Liquid Glass adds a rim highlight
        // that read as an outline around the whole bar.
        guard outerPanelEnabled else { return AnyView(content) }

        // Forced dark so labels, pills, and section fills stay light against
        // the black panel — in light mode they resolve to near-black otherwise.
        return AnyView(
            content
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
struct CommandBarSurfaceShape: Shape {
    var anchor: EdgeRevealStyle

    func path(in rect: CGRect) -> Path {
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
/// Behaviour depends on the outer Background preference (see `CommandBarSurface`):
/// - Background ON  → faint zone fill; the outer wrap supplies the real background.
/// - Background OFF, macOS 26 → per-section Liquid Glass (default look).
/// - Background OFF, macOS 14 → `.thinMaterial` over opaque base (no glass at all).
struct CommandBarSurfaceBackground: View {
    var cornerRadius: CGFloat
    var accent: Color = .clear

    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = true

    private static let zoneFillOpacity: Double = 0.05

    var body: some View {
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

extension View {
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

struct PermissionBanner: View {
    let icon: String
    let tint: Color
    let message: String
    let actionTitle: String
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var dismissAction: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)

            Text(message)
                .font(.caption)
                .lineLimit(2)

            Spacer(minLength: 8)

            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .controlSize(.small)
            }

            Button(actionTitle, action: action)
                .commandBarProminentButtonStyle()
                .controlSize(.small)
                .tint(tint)

            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CommandBarSurfaceBackground(cornerRadius: 12))
    }
}

struct SearchHeader: View {
    @Binding var searchText: String
    @FocusState.Binding var isSearchFocused: Bool
    let isSelected: Bool
    let scopeChips: [ScopeChip]
    /// Non-nil while alias mode is active — rendered as a badge between the
    /// scope chips and the caret, the way a browser address bar shows the
    /// search engine you tabbed into.
    let activeAlias: SearchAlias?
    let onRemoveAlias: () -> Void
    let focusedChipID: UUID?
    let onRemoveChip: (ScopeChip) -> Void
    let onFocusChip: (ScopeChip) -> Void
    let onBackspaceAtEmpty: () -> Void
    let onLeftArrowAtEmpty: () -> Void
    let onUpArrow: () -> Void
    let onDownArrow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            ScopeChipsRow(
                chips: scopeChips,
                focusedChipID: focusedChipID,
                onRemove: onRemoveChip,
                onFocusChip: onFocusChip
            )

            if let activeAlias {
                SearchAliasBadge(alias: activeAlias, onRemove: onRemoveAlias)
            }

            TextField(
                searchFieldPlaceholder,
                text: $searchText
            )
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .focused($isSearchFocused)
                .onKeyPress(.upArrow) {
                    onUpArrow()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onDownArrow()
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    if searchText.isEmpty && !scopeChips.isEmpty {
                        onLeftArrowAtEmpty()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.delete) {
                    if searchText.isEmpty && !scopeChips.isEmpty {
                        onBackspaceAtEmpty()
                        return .handled
                    }
                    return .ignored
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            CommandBarSurfaceBackground(
                cornerRadius: 14,
                accent: isSelected ? Color.accentColor.opacity(0.14) : Color.clear
            )
        )
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelected)
    }

    /// In alias mode the placeholder names the destination, so an empty input
    /// still says where Enter would take you.
    private var searchFieldPlaceholder: String {
        if let activeAlias { return "Search \(activeAlias.displayName)…" }
        return scopeChips.isEmpty ? "Search tabs, bookmarks, history…" : ""
    }
}

private struct SearchAliasBadge: View {
    let alias: SearchAlias
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(alias.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Leave \(alias.displayName) search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.accentColor.opacity(0.18))
        )
        .overlay(
            Capsule().strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 1)
        )
        .fixedSize()
    }
}

struct FooterShortcutBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(CommandBarSurfaceBackground(cornerRadius: 12))
    }
}

/// Shared appearance preference keys for the command bar.
enum CommandBarAppearance {
    static let outerPanelKey = "FastTab.appearance.outerGlassPanel"
    static let resultRowStyleKey = "FastTab.appearance.resultRowStyle"
    static let quickOpenItemLimitKey = "FastTab.appearance.quickOpenItemLimit"
    static let menuBarIconVisibleKey = "FastTab.appearance.showMenuBarIcon"
    static let helperPanelVisibleKey = "FastTab.appearance.showHelperPanel"
}

func commandBarFullScreenShadowColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.black : Color.black.opacity(0.72)
}
