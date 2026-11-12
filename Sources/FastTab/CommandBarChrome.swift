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
        CommandBarSearchHeaderFrame {
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
    }

    /// Active search tab: IndieCommandBar's search pill with Fast Tab's scope
    /// chips and alias badge inside.
    private var searchTab: some View {
        CommandBarSearchPill(
            text: $searchText,
            isFocused: $isSearchFocused,
            placeholder: searchFieldPlaceholder,
            highlight: tabHighlight,
            onUpArrow: onUpArrow,
            onDownArrow: onDownArrow,
            onLeftArrowAtEmpty: {
                guard !scopeChips.isEmpty else { return false }
                onLeftArrowAtEmpty()
                return true
            },
            onBackspaceAtEmpty: {
                guard !scopeChips.isEmpty else { return false }
                onBackspaceAtEmpty()
                return true
            }
        ) {
            CommandBarScopeChipsRow(
                chips: scopeChips.map { CommandBarScopeChip(id: $0.id, title: $0.displayLabel) },
                focusedChipID: focusedChipID,
                onRemove: { id in scopeChips.first { $0.id == id }.map(onRemoveChip) },
                onFocusChip: { id in scopeChips.first { $0.id == id }.map(onFocusChip) }
            )

            if let activeAlias {
                SearchAliasBadge(alias: activeAlias, onRemove: onRemoveAlias)
            }
        }
    }

    /// In alias mode the placeholder names the destination, so an empty input
    /// still says where Enter would take you.
    private var searchFieldPlaceholder: String {
        if let activeAlias { return "Search \(activeAlias.displayName)…" }
        return scopeChips.isEmpty ? "Search tabs, bookmarks, history…" : ""
    }
}

private struct SearchAliasBadge: View {
    @Environment(\.commandBarTheme) private var theme
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
            Capsule().fill(theme.accentColor.opacity(0.18))
        )
        .overlay(
            Capsule().strokeBorder(theme.accentColor.opacity(0.32), lineWidth: 1)
        )
        .fixedSize()
    }
}

/// Fast Tab's appearance preference keys. The first three are Fast Tab's copy of the shared
/// appearance model (IndieCommandBar `CommandBarAppearanceSettings`, keys `.fastTab`, names unchanged).
extension CommandBarAppearanceKeys {
    /// Fast Tab's keys. The first three predate the shared model and keep their old
    /// names so stored choices survive (pinned by `AppearanceSettingsMigrationTests`).
    static let fastTab = CommandBarAppearanceKeys(
        background: "FastTab.appearance.outerGlassPanel",
        rowStyle: "FastTab.appearance.resultRowStyle",
        rowLimit: "FastTab.appearance.quickOpenItemLimit",
        placement: "FastTab.appearance.placement",
        fitsContent: "FastTab.appearance.fitsContent",
        accent: "FastTab.appearance.accent",
        followsEdge: "FastTab.appearance.followsEdge"
    )
}

enum CommandBarAppearance {
    static let keys = CommandBarAppearanceKeys.fastTab
    static let outerPanelKey = keys.background
    static let resultRowStyleKey = keys.rowStyle
    static let quickOpenItemLimitKey = keys.rowLimit
    /// Accent colour (slice 8c). Missing = `.system`, the look before the setting existed.
    static let accentKey = keys.accent
    /// Position (slice 10): follow the hover edge (default, missing key) or a floating card at `placementKey`.
    static let followsEdgeKey = keys.followsEdge
    static let placementKey = keys.placement
    /// Fast Tab's defaults: background on, Minimal rows, 5 quick-open items, Position = follow
    /// the hover-to-open edge (General). No Size picker: the bar sizes itself.
    static let standard = CommandBarAppearanceSettings(background: true, rowStyle: .minimal, rowLimit: 5, followsEdge: true)

    static func load(from defaults: UserDefaults = .standard) -> CommandBarAppearanceSettings {
        CommandBarAppearanceSettings.load(
            from: defaults, keys: keys, fallback: standard,
            rowLimitRange: CommandBarLayout.minQuickOpenItemLimit...CommandBarLayout.maxQuickOpenItemLimit
        )
    }
    static let menuBarIconVisibleKey = "FastTab.appearance.showMenuBarIcon"
    static let helperPanelVisibleKey = "FastTab.appearance.showHelperPanel"
    static let guideBarVisibleKey = "FastTab.appearance.showGuideBar"
}
