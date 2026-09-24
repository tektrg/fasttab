import SwiftUI
import CommandBarKit

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
    /// Stack toggle shown at the leading edge: tapping switches between
    /// Recents/search and the Stack view (same as swiping horizontally).
    let isStackActive: Bool
    let onToggleStack: () -> Void

    @State private var isStackHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleStack) {
                Image(systemName: isStackActive ? "square.stack.fill" : "square.stack")
                    .font(.system(size: 15, weight: isStackActive ? .semibold : .regular))
                    .foregroundStyle(isStackActive ? Color.accentColor : (isStackHovered ? Color.primary.opacity(0.85) : Color.secondary))
                    .frame(width: 28, height: 28)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isStackActive ? Color.accentColor.opacity(0.14) : (isStackHovered ? Color.primary.opacity(0.06) : Color.clear))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { isStackHovered = $0 }
            .help(isStackActive ? "Back to Recents (⌘1)" : "Open Stack (⌘2)")
            .accessibilityLabel(Text(isStackActive ? "Back to Recents" : "Open Stack"))

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
