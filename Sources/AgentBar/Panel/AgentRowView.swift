import SwiftUI

/// One agent row. The selected row (hover or keyboard) reveals its buttons in
/// place of the age; a row waiting for a confirming press shows why, in red.
struct AgentRowView: View {
    let agent: AgentSnapshot
    let isSelected: Bool
    let fetchedAt: Date
    var actionState: RowActionState?
    /// The agent's answer is on its way: a spinner replaces the buttons.
    var isSendingAnswer = false
    var highlightedButton: RowButton?
    var onPress: (RowButton) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agent.section.dotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                detailLine
            }
        }
        .padding(.horizontal, 12)
        .frame(height: AgentPanelMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .padding(.horizontal, 10)
        .opacity(dimming)
        .contentShape(Rectangle())
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            Text(agent.label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let project = agent.projectName {
                Text(project)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isSendingAnswer {
                sendingIndicator
            } else if showsButtons {
                buttonStrip
            } else {
                AgentAgeView(agent: agent, fetchedAt: fetchedAt)
            }
        }
    }

    private var sendingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Sending answer…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityLabel("Sending answer")
    }

    private var buttons: [RowButtonSpec] { RowButtons.available(for: agent) }

    /// Buttons show on the selected row, and stay while a press is being settled.
    /// A blocked row always shows its red button, so it cannot be missed.
    private var showsButtons: Bool {
        !visibleButtons.isEmpty && (isSelected || actionState != nil || agent.blockedOnYou != nil)
    }

    /// Selected (or settling): every button. Otherwise only the blocked row's red one.
    private var visibleButtons: [RowButtonSpec] {
        isSelected || actionState != nil ? buttons : buttons.filter { agent.blockedOnYou != nil && $0.button.isBlockedAction }
    }

    private var buttonStrip: some View {
        HStack(spacing: 6) {
            ForEach(visibleButtons, id: \.button.title) { spec in
                RowActionButtonView(
                    spec: spec,
                    state: actionState,
                    isHighlighted: highlightedButton == spec.button,
                    onPress: { onPress(spec.button) }
                )
            }
        }
    }

    private var detailLine: some View {
        HStack(spacing: 8) {
            Text(detailText)
                .font(.system(size: 12))
                .foregroundStyle(isConfirming ? Color.red : .secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if agent.hasUnpushedCommits {
                UnpushedBadgeView(detail: agent.unpushedText)
            }
        }
    }

    private var isConfirming: Bool {
        if case .confirming? = actionState { return true }
        return false
    }

    /// The status line, or the stake and "Confirm?" while a press awaits its second press.
    private var detailText: String {
        if case .confirming(let button, let reason)? = actionState, let kind = button.sessionAction {
            return RowActionText.confirmPrompt(kind: kind, reason: reason)
        }
        return agent.statusText
    }

    /// Ended rows are clearly out of play (unless their pane is still open and
    /// waiting to be closed); non-Claude panes are a shade quieter because
    /// their status is only a guess.
    private var dimming: Double {
        if agent.section == .ended { return agent.canFocus ? 0.85 : 0.45 }
        return agent.hasHookData ? 1 : 0.7
    }
}
