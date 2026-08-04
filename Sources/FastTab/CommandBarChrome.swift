import SwiftUI

struct CommandBarSurface<Content: View>: View {
    /// Which screen edge the bar hugs — determines the outer shape below
    /// (flat on that side, rounded on the rest). See `CommandBarLayout.surfaceCorners`.
    var anchor: EdgeRevealStyle
    @ViewBuilder var content: Content
    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = false

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

        let corners = CommandBarLayout.surfaceCorners(for: anchor)
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: corners.topLeading,
            bottomLeadingRadius: corners.bottomLeading,
            bottomTrailingRadius: corners.bottomTrailing,
            topTrailingRadius: corners.topTrailing,
            style: .continuous
        )

        // Forced dark so labels, pills, and section fills stay light against
        // the black panel — in light mode they resolve to near-black otherwise.
        return AnyView(
            content
                .environment(\.colorScheme, .dark)
                .background(shape.fill(Color.black))
        )
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

    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = false

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

            TextField(
                scopeChips.isEmpty ? "Search tabs, bookmarks, history…" : "",
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
}

func commandBarFullScreenShadowColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.black : Color.black.opacity(0.72)
}
