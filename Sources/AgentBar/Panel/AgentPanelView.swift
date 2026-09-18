import SwiftUI

/// Panel content: search field, then the list or a status message, then the
/// optional stale-board note. Total height is dictated by `AgentPanelMetrics`.
struct AgentPanelView: View {
    @ObservedObject var model: AgentPanelModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SearchFieldView(model: model, onClose: onClose)
            Divider()
            bodyContent
            if model.presentation.showsBoardNote {
                BoardNoteView()
            }
        }
        .frame(width: AgentPanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
    }

    @ViewBuilder
    private var bodyContent: some View {
        if model.presentation.state == .list {
            AgentListView(
                model: model,
                rows: model.presentation.rows,
                fetchedAt: model.snapshot?.fetchedAt ?? Date()
            )
        } else {
            StatusMessageView(state: model.presentation.state)
        }
    }
}
