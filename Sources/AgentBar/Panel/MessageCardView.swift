import SwiftUI

/// The message card: replaces the list while a line is being typed to an agent. Top to bottom:
/// who, what the agent last said (for context), the text box, then the bar with the state of the
/// send and the Send button. Fills exactly `bodyHeight`. Return sends (see `MultiLineAnswerField`,
/// the one place that owns the text focus), Esc goes back.
struct MessageCardView: View {
    @ObservedObject var message: MessageCardModel
    let bodyHeight: CGFloat
    /// The agent whose details were just copied (for the "Copied" feedback), and the copy action.
    var copiedAgentID: String?
    var onCopy: () -> Void = {}
    var onOpen: () -> Void = {}

    static let fieldHeight: CGFloat = 78

    var body: some View {
        if let card = message.card {
            VStack(alignment: .leading, spacing: 0) {
                header(card)
                ScrollView {
                    LastMessageSection(message: card.message)
                        .padding(.bottom, 4)
                }
                composer(card)
                bottomBar(card)
            }
            .frame(height: bodyHeight)
        }
    }

    // MARK: - Sections

    private func header(_ card: MessageCard) -> some View {
        HStack(spacing: 8) {
            Text(card.label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let project = card.projectName {
                Text(project)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            OpenAgentButton(onOpen: onOpen)
            CopyIdentityButton(isCopied: copiedAgentID == card.agentID, showsLabel: true, onCopy: onCopy)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.answerHeaderHeight)
    }

    /// The text box, then one line about the draft itself (why it cannot go, the line-break note, the counter).
    private func composer(_ card: MessageCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                MultiLineAnswerField(
                    text: Binding(get: { card.draft }, set: { message.setDraft($0) }),
                    onSubmit: { message.pressSend() },
                    onLeave: { message.handleEscape() }
                )
                if card.draft.isEmpty {
                    Text("Message \(card.label)…   ↩ sends")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(height: Self.fieldHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            draftLine(card)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func draftLine(_ card: MessageCard) -> some View {
        HStack(spacing: 8) {
            if let hint = card.draftHint {
                Text(hint)
                    .foregroundStyle(.red)
            } else if card.showsLineBreakNote {
                Text("Line breaks are sent as spaces.")
                    .foregroundStyle(.secondary)
            } else if let caption = card.routeCaption {
                // Inbox route (Claude Desktop / CLI): said here so the fixed-height card never grows.
                Text(caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let counter = card.counterText {
                Text(counter)
                    .foregroundStyle(card.draftHint == nil ? .secondary : Color.red)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .frame(minHeight: 14)
    }

    private func bottomBar(_ card: MessageCard) -> some View {
        HStack(spacing: 10) {
            statusText(card)
            Spacer(minLength: 0)
            Button(card.sendTitle) { message.pressSend() }
                .disabled(!card.canSend)
                .tint(card.isConfirming ? .orange : nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .frame(minHeight: AgentPanelMetrics.answerBottomBarHeight)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private func statusText(_ card: MessageCard) -> some View {
        if card.phase == .sending {
            ProgressView().controlSize(.small)
            Text("Checking the terminal, then sending…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        } else if let error = card.errorText {
            Text(error)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } else if card.isConfirming {
            Text(MessageCard.midTurnConfirmText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(WarningTextColor.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
