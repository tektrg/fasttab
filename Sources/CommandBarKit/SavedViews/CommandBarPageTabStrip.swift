import SwiftUI
import AppKit

/// One entry of the header page switcher.
public struct CommandBarPageTab<Builtin: CommandBarBuiltinPage>: Identifiable, Equatable {
    public let page: CommandBarPage<Builtin>
    public let title: String
    public let icon: String
    /// ⌘N shortcut number (`CommandBarPage.numberedShortcutTarget`), nil when
    /// the page has none (New View, or past ⌘9).
    public let shortcutNumber: Int?
    /// Tooltip before the shortcut suffix; defaults to `title`.
    public let helpBase: String

    public init(page: CommandBarPage<Builtin>, title: String, icon: String, shortcutNumber: Int?, helpBase: String? = nil) {
        self.page = page
        self.title = title
        self.icon = icon
        self.shortcutNumber = shortcutNumber
        self.helpBase = helpBase ?? title
    }

    public var id: CommandBarPage<Builtin> { page }

    public var help: String {
        shortcutNumber.map { "\(helpBase) (⌘\($0))" } ?? helpBase
    }

    /// Tabs for `ordered` (swipe order), numbered like ⌘1…⌘9. `describe`
    /// gives each page's title, icon and optional tooltip base.
    public static func tabs(
        for ordered: [CommandBarPage<Builtin>],
        describe: (CommandBarPage<Builtin>) -> (title: String, icon: String, help: String?)
    ) -> [Self] {
        zip(ordered, CommandBarPage<Builtin>.shortcutNumbers(in: ordered)).map { page, number in
            let d = describe(page)
            return Self(page: page, title: d.title, icon: d.icon, shortcutNumber: number, helpBase: d.help)
        }
    }
}

/// The page tabs of a command-bar header. Inactive tabs are icons; the active
/// one is icon + name on the sliding accent pill. Overflow scrolls
/// horizontally instead of squeezing the search field or clipping: beside a
/// search box the icons are capped to a few inline slots (`capsInlineIcons`);
/// otherwise the row stays compact and centered as long as it fits, and
/// becomes a scroll strip (kept on the active tab) when it doesn't.
public struct CommandBarPageTabStrip<Builtin: CommandBarBuiltinPage>: View {
    let tabs: [CommandBarPageTab<Builtin>]
    let activePage: CommandBarPage<Builtin>
    let highlight: Namespace.ID
    let onSelect: (CommandBarPage<Builtin>) -> Void
    let capsInlineIcons: Bool
    /// Saved-view tab context menu ("Edit View…" / "Delete View…").
    let onEditView: ((UUID) -> Void)?
    let onDeleteView: ((UUID) -> Void)?

    @Environment(\.isCompactCommandBar) private var isCompact

    private static var iconSize: CGFloat { 28 }
    private static var spacing: CGFloat { 6 }

    public init(
        tabs: [CommandBarPageTab<Builtin>],
        activePage: CommandBarPage<Builtin>,
        highlight: Namespace.ID,
        onSelect: @escaping (CommandBarPage<Builtin>) -> Void,
        capsInlineIcons: Bool,
        onEditView: ((UUID) -> Void)? = nil,
        onDeleteView: ((UUID) -> Void)? = nil
    ) {
        self.tabs = tabs
        self.activePage = activePage
        self.highlight = highlight
        self.onSelect = onSelect
        self.capsInlineIcons = capsInlineIcons
        self.onEditView = onEditView
        self.onDeleteView = onDeleteView
    }

    public var body: some View {
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
                // into view: on appear (⌘N / a flick rebuilds the strip —
                // scroll after the first layout pass, or `scrollTo` is a
                // no-op), on switch, and when tabs are added/renamed.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) { row }
                        .fixedSize(horizontal: false, vertical: true)
                        .onAppear {
                            proxy.scrollTo(activePage, anchor: .center)
                            DispatchQueue.main.async { proxy.scrollTo(activePage, anchor: .center) }
                        }
                        .onChange(of: activePage) { _, page in
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(page, anchor: .center) }
                        }
                        .onChange(of: tabs) { _, _ in
                            DispatchQueue.main.async { proxy.scrollTo(activePage, anchor: .center) }
                        }
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: Self.spacing) {
            ForEach(tabs) { tab in
                tabView(tab)
                    .id(tab.page)
                    .contextMenu { contextMenu(for: tab) }
            }
        }
    }

    @ViewBuilder
    private func tabView(_ tab: CommandBarPageTab<Builtin>) -> some View {
        if tab.page == activePage {
            activePill(tab)
        } else {
            HeaderTabIcon(icon: tab.icon, help: tab.help, label: tab.help) { onSelect(tab.page) }
        }
    }

    /// Icon (filled when the symbol has a fill variant) plus name, on the
    /// accent pill.
    private func activePill(_ tab: CommandBarPageTab<Builtin>) -> some View {
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
    private func contextMenu(for tab: CommandBarPageTab<Builtin>) -> some View {
        if let id = tab.page.customID {
            if let onEditView { Button("Edit View…") { onEditView(id) } }
            if let onDeleteView { Button("Delete View…", role: .destructive) { onDeleteView(id) } }
        }
    }

    private static func filledSymbol(_ name: String) -> String {
        guard !name.hasSuffix(".fill") else { return name }
        let filled = name + ".fill"
        return NSImage(systemSymbolName: filled, accessibilityDescription: nil) != nil ? filled : name
    }
}

/// Icon-only inactive header tab with hover feedback.
public struct HeaderTabIcon: View {
    let icon: String
    let help: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    public init(icon: String, help: String, label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.help = help
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(isHovered ? Color.primary.opacity(0.85) : Color.secondary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(Text(label))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}
