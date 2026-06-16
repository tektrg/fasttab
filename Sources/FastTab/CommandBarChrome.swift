import SwiftUI

struct CommandBarSurface<Content: View>: View {
    @ViewBuilder var content: Content
    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = false

    var body: some View {
        // When the user enables the outer panel, the whole bar gets one Liquid
        // Glass shape. Inner sections then render a faint zone fill instead of
        // their own glass (CommandBarSurfaceBackground reads the same key).
        // On macOS 14 the outer panel is never shown — each section keeps its
        // own frosted material regardless.
        if #available(macOS 26.0, *), outerPanelEnabled {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: CommandBarLayout.surfaceCornerRadius, style: .continuous)
            )
        } else {
            content
        }
    }
}

/// Background for a single command-bar section.
///
/// Behaviour depends on two conditions: OS version and the outer-panel preference.
/// - macOS 26, outer panel OFF → per-section Liquid Glass (default look).
/// - macOS 26, outer panel ON  → faint zone fill; glass comes from the outer panel.
/// - macOS 14                  → `.thinMaterial` over opaque base (no glass at all).
struct CommandBarSurfaceBackground: View {
    var cornerRadius: CGFloat
    var accent: Color = .clear

    @AppStorage(CommandBarAppearance.outerPanelKey) private var outerPanelEnabled: Bool = false

    private static let zoneFillOpacity: Double = 0.05

    var body: some View {
        if #available(macOS 26.0, *) {
            if outerPanelEnabled {
                zoneFillBackground
            } else {
                liquidGlassBackground
            }
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

    // Faint fill used when the outer panel supplies the glass layer.
    @available(macOS 26.0, *)
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
                .font(.system(size: 22, weight: .semibold, design: .rounded))
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
