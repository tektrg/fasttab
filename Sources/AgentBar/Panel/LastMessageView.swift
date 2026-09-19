import SwiftUI

/// The agent's latest message on the answer card: a few lines, with Show more
/// when there is more, so it never takes the room the question needs.
struct LastMessageView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LAST MESSAGE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(isExpanded ? nil : AnswerCardLayout.messageLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if AnswerCardLayout.messageNeedsToggle(text) {
                Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .id(text)
    }
}
