import SwiftUI
import IndieCommandBar

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
    /// The view switcher: one tab per page in swipe order (Recents/search,
    /// Stack, custom views, "＋ New View") — the same destinations as swiping
    /// horizontally or ⌘1…⌘9. The active tab wears the accent pill (the full
    /// search box for Recents, otherwise icon plus name); inactive tabs are
    /// just icons. The pill slides between tabs on switch. See
    /// `CommandBarViewTabStrip`.
    let activeView: CommandBarView
    let viewTabs: [CommandBarViewTab]
    let onSelectView: (CommandBarView) -> Void
    let onEditView: (UUID) -> Void
    let onDeleteView: (UUID) -> Void

    @Namespace private var tabHighlight

    private func selectTab(_ id: String) {
        if let view = CommandBarView(rawValue: id) { onSelectView(view) }
    }

    private func runTabMenuAction(_ tab: CommandBarViewTab, _ action: CommandBarRowAction) {
        guard let id = tab.view?.customID else { return }
        switch action.id {
        case FastTabViewMenu.editID: onEditView(id)
        case FastTabViewMenu.deleteID: onDeleteView(id)
        default: break
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if activeView == .recents {
                searchTab
                CommandBarViewTabStrip(
                    tabs: viewTabs.filter { $0.view != .recents },
                    activeID: activeView.rawValue,
                    highlight: tabHighlight,
                    onSelect: selectTab,
                    contextActions: FastTabViewMenu.actions(for:),
                    onContextAction: runTabMenuAction,
                    capsInlineIcons: true
                )
            } else {
                CommandBarViewTabStrip(
                    tabs: viewTabs,
                    activeID: activeView.rawValue,
                    highlight: tabHighlight,
                    onSelect: selectTab,
                    contextActions: FastTabViewMenu.actions(for:),
                    onContextAction: runTabMenuAction,
                    capsInlineIcons: false
                )
            }
        }
        .padding(4)
        .background(
            CommandBarSurfaceBackground(
                cornerRadius: 14,
                accent: .clear
            )
        )
    }

    /// Active search tab: the full search box riding the sliding pill.
    private var searchTab: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            CommandBarScopeChipsRow(
                chips: scopeChips.map { CommandBarScopeChip(id: $0.id, title: $0.displayLabel) },
                focusedChipID: focusedChipID,
                onRemove: { id in scopeChips.first { $0.id == id }.map(onRemoveChip) },
                onFocusChip: { id in scopeChips.first { $0.id == id }.map(onFocusChip) }
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
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .matchedGeometryEffect(id: "HeaderTabHighlight", in: tabHighlight)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
    static let guideBarVisibleKey = "FastTab.appearance.showGuideBar"
}

func commandBarFullScreenShadowColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.black : Color.black.opacity(0.72)
}
