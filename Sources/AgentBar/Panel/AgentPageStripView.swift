import SwiftUI
import CommandBarKit

/// The page tabs above the agent list: All, the saved views, "＋ New view". Right-click a saved
/// view for Edit / Delete.
struct AgentPageStripView: View {
    @ObservedObject var pages: AgentPagesModel
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            CommandBarPageTabStrip(
                tabs: pages.tabs,
                activePage: pages.activePage,
                highlight: highlight,
                onSelect: { page in withAnimation(.easeOut(duration: 0.18)) { pages.select(page) } },
                capsInlineIcons: false,
                onEditView: { pages.beginEdit(id: $0) },
                onDeleteView: { pages.beginEdit(id: $0, confirmingDelete: true) }
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: AgentPanelMetrics.pageStripHeight)
    }
}
