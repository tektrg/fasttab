import SwiftUI

/// The question a Claude Desktop turn ended on (its wrap_up box), at the top of the message card: the ask, the
/// recap under it, and one button per action — a click sends that action's message (`pressWrapUpAction`).
/// The first action is the agent's recommendation, so it is the prominent one.
struct WrapUpQuestionSection: View {
    let question: WrapUpQuestion
    let isEnabled: Bool
    let onAction: (WrapUpQuestion.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.ask)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if !question.recap.isEmpty {
                Text(question.recap)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                ForEach(Array(question.actions.enumerated()), id: \.offset) { index, action in
                    actionButton(action, isRecommended: index == 0)
                }
                Spacer(minLength: 0)
            }
            let consentLabels = question.actions.filter(\.mayNeedConfirming).map(\.label)
            if !consentLabels.isEmpty {
                Text("\(WrapUpQuestion.consentNote): \(consentLabels.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private func actionButton(_ action: WrapUpQuestion.Action, isRecommended: Bool) -> some View {
        let button = Button(action.label) { onAction(action) }
            .disabled(!isEnabled)
            .help(action.message)
            .lineLimit(1)
        if isRecommended {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
