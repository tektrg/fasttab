import SwiftUI

/// The corner tab's card mode: the exact Answer / Review card the main panel would show for the
/// sole blocked agent (question, permission, plan or multi-question form — `AnswerCardView`/
/// `PermissionCardView` already pick the right one), topped by a slim header (red dot, "Waiting
/// for your answer", an expand button) and the same footer the panel uses (hints, and any
/// dismissible notice). `model` is the shared `AgentPanelModel`, so the card is the live one
/// `AgentPanelModel.openCardForCorner` opened: option clicks, Send, plan feedback and footer
/// notices all behave exactly as they do in the main panel.
struct CornerCardView: View {
    @ObservedObject var model: AgentPanelModel
    let onExpand: () -> Void
    let onDismiss: () -> Void
    let onOpenSettings: () -> Void

    private var bodyHeight: CGFloat { AgentPanelMetrics.fullBodyHeight() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            cardBody
            PanelFooterView(
                notice: model.footerNotice,
                hintContext: .init(
                    isPeeking: false,
                    hasHighlightedButton: false,
                    searchIsEmpty: true,
                    answerMode: model.answer.card?.hintMode,
                    permissionMode: model.permission.card?.hintMode,
                    messageMode: nil,
                    hasDismissibleNotice: model.footerNotice?.isDismissible == true
                ),
                onOpenSettings: onOpenSettings
            )
        }
        .frame(width: AgentPanelMetrics.width)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { failureNotice }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 9, height: 9)
            Text("Waiting for your answer")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open the full switcher")
            .accessibilityLabel("Open AgentBar")
            CornerDismissButton(action: onDismiss)
        }
        .padding(.horizontal, 14)
        .frame(height: CornerTabPlacement.cardHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onExpand)
    }

    @ViewBuilder
    private var cardBody: some View {
        if model.answer.isOpen {
            AnswerCardView(
                answer: model.answer, bodyHeight: bodyHeight,
                copiedAgentID: model.copier.copiedAgentID, onCopy: { model.copyOpenCardIdentity() },
                onOpen: { model.openCardAgent() }
            )
        } else if model.permission.isOpen {
            PermissionCardView(
                permission: model.permission, bodyHeight: bodyHeight,
                copiedAgentID: model.copier.copiedAgentID, onCopy: { model.copyOpenCardIdentity() },
                onOpen: { model.openCardAgent() }
            )
        } else {
            // The blocker resolved between the machine's effect and this redraw (the next status
            // read will close the corner down to the pill); nothing to show for the instant between.
            Color.clear.frame(height: bodyHeight)
        }
    }

    @ViewBuilder
    private var failureNotice: some View {
        if let notice = model.footerNotice, notice.isDismissible {
            FooterNoticeView(notice: notice) { model.dismissFooterNotice() }
                .padding(.bottom, AgentPanelMetrics.footerHeight)
        }
    }
}

/// The ✕ shared by the pill and the card header: hides the corner for now (the agent stays blocked
/// in the panel; only a new blocker or resting the pointer in the corner brings it back).
struct CornerDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide for now")
        .accessibilityLabel("Dismiss")
    }
}
