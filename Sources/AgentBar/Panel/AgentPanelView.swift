import SwiftUI

/// Panel content: search field, then the list or a status message, then the
/// optional stale-board note and the footer (a failure notice floats above it). Total height is dictated by
/// `AgentPanelMetrics`. Tab-tagged (`AgentPanelModel.taggedAgentID`): the list/status message and the
/// board note are both hidden — the target is already chosen (shown as a chip in the search field
/// itself), so there's nothing left to pick from, and showing it anyway would just be clutter.
struct AgentPanelView: View {
    @ObservedObject var model: AgentPanelModel
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SearchFieldView(model: model, onClose: onClose)
            Divider()
            bodyContent
            if model.presentation.showsBoardNote, model.taggedAgentID == nil {
                BoardNoteView()
            }
            PanelFooterView(
                notice: model.footerNotice,
                hintContext: .init(
                    isPeeking: model.peek != nil,
                    hasHighlightedButton: model.highlightedButton != nil,
                    searchIsEmpty: model.query.isEmpty,
                    answerMode: model.answer.card?.hintMode,
                    permissionMode: model.permission.card?.hintMode,
                    messageMode: model.message.card?.hintMode,
                    hasDismissibleNotice: model.footerNotice?.isDismissible == true,
                    routingMode: model.routingState.map { switch $0 {
                        case .loading: .loading
                        case .confirming: .confirming
                    } },
                    isTagged: model.taggedAgentID != nil
                ),
                onOpenSettings: onOpenSettings
            )
        }
        .frame(width: AgentPanelMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { failureNotice }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
    }

    /// A failure stays over the bottom of the body, above the footer, until dismissed.
    @ViewBuilder
    private var failureNotice: some View {
        if let notice = model.footerNotice, notice.isDismissible {
            FooterNoticeView(notice: notice) { model.dismissFooterNotice() }
                .padding(.bottom, AgentPanelMetrics.footerHeight)
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if model.answer.isOpen {
            AnswerCardView(
                answer: model.answer,
                bodyHeight: AgentPanelMetrics.fullBodyHeight(
                    maxListHeight: AgentPanelMetrics.maxListHeight(visibleRows: model.listSettings.maxVisibleRows)
                ),
                copiedAgentID: model.copier.copiedAgentID,
                onCopy: { model.copyOpenCardIdentity() }
            )
        } else if model.permission.isOpen {
            PermissionCardView(
                permission: model.permission,
                bodyHeight: AgentPanelMetrics.fullBodyHeight(
                    maxListHeight: AgentPanelMetrics.maxListHeight(visibleRows: model.listSettings.maxVisibleRows)
                ),
                copiedAgentID: model.copier.copiedAgentID,
                onCopy: { model.copyOpenCardIdentity() }
            )
        } else if model.message.isOpen {
            MessageCardView(
                message: model.message,
                bodyHeight: AgentPanelMetrics.fullBodyHeight(
                    maxListHeight: AgentPanelMetrics.maxListHeight(visibleRows: model.listSettings.maxVisibleRows)
                ),
                copiedAgentID: model.copier.copiedAgentID,
                onCopy: { model.copyOpenCardIdentity() }
            )
        } else if let peek = model.peek {
            PanePeekView(
                peek: peek,
                bodyHeight: AgentPanelMetrics.peekBodyHeight(
                    maxListHeight: AgentPanelMetrics.maxListHeight(visibleRows: model.listSettings.maxVisibleRows)
                )
            )
        } else if model.taggedAgentID != nil {
            // Composing: the target is already chosen (the chip in the search field), so the
            // list/status below has nothing left to contribute — matches
            // `AgentPanelMetrics.height(isComposing:)` collapsing this area to zero height.
            EmptyView()
        } else if model.presentation.state == .list {
            AgentListView(
                model: model,
                rows: model.presentation.rows,
                fetchedAt: model.snapshot?.fetchedAt ?? Date()
            )
        } else {
            StatusMessageView(state: model.presentation.state, dashboardAddress: model.dashboardAddress)
        }
    }
}
