import SwiftUI
import IndieCommandBar

/// The page tabs above the agent list: All, the saved views, "＋ New view". Right-click a saved
/// view for Edit / Delete. Drawn by the shared `CommandBarViewTabStrip`, like Fast Tab's views.
struct AgentPageStripView: View {
    @ObservedObject var pages: AgentPagesModel
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            CommandBarViewTabStrip(
                tabs: pages.tabs,
                activeID: pages.activePage.id,
                highlight: highlight,
                onSelect: { id in
                    guard let page = pages.page(forTabID: id) else { return }
                    withAnimation(.easeOut(duration: 0.18)) { pages.select(page) }
                },
                contextActions: CommandBarSavedViewMenu.actions(for:),
                onContextAction: { tab, action in
                    guard let id = pages.page(forTabID: tab.id)?.customID else { return }
                    pages.beginEdit(id: id, confirmingDelete: action.id == CommandBarSavedViewMenu.deleteID)
                },
                capsInlineIcons: false
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: AgentPanelMetrics.pageStripHeight)
    }
}
