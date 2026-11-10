import SwiftUI
import AppKit
import CommandBarKit

/// One entry of the header view switcher (`SearchHeader`).
struct CommandBarViewTab: Identifiable, Equatable {
    let view: CommandBarView
    let title: String
    let icon: String
    /// ⌘N shortcut number (`CommandBarView.numberedShortcutTarget`), nil when
    /// the page has none (New View, or past ⌘9).
    let shortcutNumber: Int?

    var id: CommandBarView { view }

    var help: String {
        let base: String
        switch view {
        case .recents: base = "Search"
        case .stack: base = "Open Stack"
        case .custom, .newView: base = title
        }
        return shortcutNumber.map { "\(base) (⌘\($0))" } ?? base
    }

    /// Header tabs for `ordered` (swipe order). Recents shows as the search
    /// magnifier, as it always has.
    static func tabs(for ordered: [CommandBarView], customViews: [CustomView]) -> [CommandBarViewTab] {
        var number = 0
        return ordered.map { view in
            var shortcut: Int?
            if view != .newView {
                number += 1
                if number <= 9 { shortcut = number }
            }
            return CommandBarViewTab(
                view: view,
                title: view == .recents ? "Search" : view.displayName(customViews: customViews),
                icon: view == .recents ? "magnifyingglass" : view.iconName(customViews: customViews),
                shortcutNumber: shortcut
            )
        }
    }
}

/// The view tabs of the header. Inactive tabs are icons; the active one (when
/// it isn't the Recents search box) is icon + name on the sliding accent
/// pill. Overflow scrolls horizontally instead of squeezing the search field
/// or clipping: beside the search box the icons are capped to a few inline
/// slots (`capsInlineIcons`); otherwise the row stays compact and centered as
/// long as it fits, and becomes a scroll strip (kept on the active tab) when
/// it doesn't.
struct CommandBarViewTabStrip: View {
    let tabs: [CommandBarViewTab]
    let activeView: CommandBarView
    let highlight: Namespace.ID
    let onSelect: (CommandBarView) -> Void
    /// Context-menu "Edit View…" / "Delete View…" on a custom view tab.
    let onEditView: (UUID) -> Void
    let onDeleteView: (UUID) -> Void
    let capsInlineIcons: Bool

    @Environment(\.isCompactCommandBar) private var isCompact

    private static let iconSize: CGFloat = 28
    private static let spacing: CGFloat = 6

    var body: some View {
        if capsInlineIcons {
            let cap = isCompact ? 3 : 5
            if tabs.count > cap {
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .frame(width: CGFloat(cap) * Self.iconSize + CGFloat(cap - 1) * Self.spacing)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                row
            }
        } else {
            ViewThatFits(in: .horizontal) {
                row
                // The strip can't be trackpad-scrolled (a horizontal swipe
                // switches pages), so the active pill must always be brought
                // into view: on appear (⌘N / a flick from Recents rebuilds the
                // strip — scroll after the first layout pass, or `scrollTo`
                // is a no-op), on switch, and when tabs are added/renamed.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { row }
                        .fixedSize(horizontal: false, vertical: true)
                        .onAppear {
                            proxy.scrollTo(activeView, anchor: .center)
                            DispatchQueue.main.async { proxy.scrollTo(activeView, anchor: .center) }
                        }
                        .onChange(of: activeView) { _, view in
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(view, anchor: .center) }
                        }
                        .onChange(of: tabs) { _, _ in
                            DispatchQueue.main.async { proxy.scrollTo(activeView, anchor: .center) }
                        }
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: Self.spacing) {
            ForEach(tabs) { tab in
                tabView(tab)
                    .id(tab.view)
                    .contextMenu { contextMenu(for: tab) }
            }
        }
    }

    @ViewBuilder
    private func tabView(_ tab: CommandBarViewTab) -> some View {
        if tab.view == activeView {
            activePill(tab)
        } else {
            HeaderTabIcon(icon: tab.icon, help: tab.help, label: tab.help) { onSelect(tab.view) }
        }
    }

    /// Same look as the original Stack tab: icon (filled when the symbol has
    /// a fill variant) plus name, on the accent pill.
    private func activePill(_ tab: CommandBarViewTab) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Self.filledSymbol(tab.icon))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(tab.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 170, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .matchedGeometryEffect(id: "HeaderTabHighlight", in: highlight)
        }
        .help(tab.help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSelected)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    @ViewBuilder
    private func contextMenu(for tab: CommandBarViewTab) -> some View {
        if let id = tab.view.customID {
            Button("Edit View…") { onEditView(id) }
            Button("Delete View…", role: .destructive) { onDeleteView(id) }
        }
    }

    private static func filledSymbol(_ name: String) -> String {
        guard !name.hasSuffix(".fill") else { return name }
        let filled = name + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil ? filled : name
    }
}
