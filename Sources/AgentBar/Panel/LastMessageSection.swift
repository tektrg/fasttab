import SwiftUI

/// The "agent's latest message" block of a card: a spinner line while the transcript is read,
/// the message itself, or nothing when the agent has said nothing.
struct LastMessageSection: View {
    let message: AnswerCard.Message

    var body: some View {
        switch message {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the agent's last message…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        case .text(let text):
            LastMessageView(text: text)
        case .none:
            EmptyView()
        }
    }
}
