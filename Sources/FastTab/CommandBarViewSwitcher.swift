import SwiftUI

struct CommandBarViewSwitcher: View {
    @ObservedObject var viewStore: CommandBarViewStore
    @State private var hoveredView: CommandBarView?
    @Namespace private var tabSwitcherAnimation

    var body: some View {
        HStack(spacing: 3) {
            ForEach(CommandBarView.allCases, id: \.self) { view in
                viewTab(view)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
        .frame(height: CommandBarLayout.viewSwitcherAllowance)
    }

    @ViewBuilder
    private func viewTab(_ view: CommandBarView) -> some View {
        let isSelected = viewStore.activeView == view
        let isHovered = hoveredView == view

        Button {
            viewStore.selectView(view)
        } label: {
            Image(systemName: iconName(for: view))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : (isHovered ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.8)))
                .frame(width: 34, height: 24)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.12))
                            .matchedGeometryEffect(id: "activeTabIndicator", in: tabSwitcherAnimation)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredView = hovering ? view : nil
        }
        .help("\(view.displayName) (\(shortcutHint(for: view)))")
        .accessibilityLabel(Text("\(view.displayName), \(shortcutHint(for: view))"))
    }

    private func iconName(for view: CommandBarView) -> String {
        view.iconName
    }

    private func shortcutHint(for view: CommandBarView) -> String {
        switch view {
        case .recents: return "⌘1"
        case .myOrder: return "⌘2"
        case .bookmarks: return "⌘3"
        }
    }
}
