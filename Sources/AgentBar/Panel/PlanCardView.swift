import SwiftUI

/// The plan card: the permission card's shell for a plan-approval box (Claude's plan mode). Top to
/// bottom: who, what the agent last said, the plan itself (scrolls), then, fixed above the action
/// bar, the question and the box's own rows verbatim. Nothing is preselected. Keys are handled by
/// the search field (see `SearchFieldView`); the feedback row opens a text box (`MultiLineAnswerField`).
struct PlanCardView: View {
    @ObservedObject var permission: PermissionCardModel
    let card: PermissionCard
    let plan: PlanCardState
    let bodyHeight: CGFloat
    var copiedAgentID: String?
    var onCopy: () -> Void = {}

    static let feedbackFieldHeight: CGFloat = 62

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentCardHeader(
                label: card.label, projectName: card.projectName, agentID: card.agentID,
                copiedAgentID: copiedAgentID, onCopy: onCopy
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LastMessageSection(message: card.message)
                    PlanTextView(file: card.planFile, path: plan.prompt.planPath)
                }
                .padding(.bottom, 4)
            }
            Divider()
            questionAndRows
            bottomBar
        }
        .frame(height: bodyHeight)
    }

    // MARK: - The box's own words

    private var questionAndRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.prompt.title)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.top, 8)
            if let note = plan.changedNote {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WarningTextColor.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }
            if let warning = card.sentWarning {
                Text(warning)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WarningTextColor.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
            }
            switch plan.phase {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking the terminal's prompt before you answer…")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
            case .unavailable(let reason):
                Text(reason)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
            case .ready:
                VStack(spacing: 2) {
                    ForEach(plan.options, id: \.index) { option in row(option) }
                }
                .padding(.horizontal, 6)
                if plan.isTypingFeedback { feedbackField }
            }
        }
        .padding(.bottom, 4)
    }

    private func row(_ option: PermissionPrompt.Option) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(option.index)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(option.label)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(plan.highlightedIndex == option.index ? Color.accentColor.opacity(0.22) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { permission.clickPlanOption(index: option.index) }
    }

    /// Return sends, Shift+Return adds a line, Esc goes back to the rows (`MultiLineAnswerField`).
    private var feedbackField: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                MultiLineAnswerField(
                    text: Binding(get: { plan.feedbackText }, set: { permission.setFeedbackText($0) }),
                    onSubmit: { permission.pressSend() },
                    onLeave: { permission.handle(.escape) }
                )
                if plan.feedbackText.isEmpty {
                    Text("What should Claude change?   ↩ sends")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(height: Self.feedbackFieldHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            Text(plan.isFeedbackTooLong ? PlanCardState.feedbackTooLongNote : PlanCardState.feedbackNote)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(plan.isFeedbackTooLong ? WarningTextColor.color : .secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
    }

    // MARK: - Action bar

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let confirmText = plan.confirmText {
                Text(confirmText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                switch plan.phase {
                case .unavailable:
                    Button("Open terminal") { permission.openTerminal() }
                case .checking, .ready:
                    Button(plan.actionTitle) { permission.pressSend() }
                        .disabled(!plan.canSend)
                        .tint(plan.isConfirmingPrivilege ? .red : nil)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(minHeight: AgentPanelMetrics.answerBottomBarHeight)
        .background(Color.primary.opacity(0.04))
    }
}
