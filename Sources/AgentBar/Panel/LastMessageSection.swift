import SwiftUI

/// The "agent's latest message" block of a card, as a FOLD: one fixed-height title row ("Last
/// message" + chevron) that is the only thing drawn until the user clicks it. The row never changes
/// height, whatever the message is doing (still being read, loaded, or empty): all of that happens
/// below it, and only once the fold is open. Before, the section grew from a one-line spinner to a
/// five-line block while the transcript loaded and pushed the question underneath it down.
///
/// Open/closed lives in this view's own `@State`: every card starts collapsed and a card that is
/// closed and reopened starts collapsed again (per-open reset, nothing persisted). The state sits on
/// the fold, above the loading/text switch, so the message arriving does not reset it.
struct LastMessageSection: View {
    let message: AnswerCard.Message
    @State private var isExpanded: Bool

    /// The title row and the gap under it: the whole height of a collapsed section.
    static let titleRowHeight: CGFloat = 24
    static let collapsedHeight: CGFloat = titleRowHeight + 6

    init(message: AnswerCard.Message, startsExpanded: Bool = false) {
        self.message = message
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            if isExpanded { content }
        }
    }

    private var titleRow: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Text("Last message")
                    .font(.avenir(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .frame(height: Self.titleRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, Self.collapsedHeight - Self.titleRowHeight)
        .help(isExpanded ? "Hide the agent's last message" : "Show the agent's last message")
        .accessibilityLabel("Last message")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }

    @ViewBuilder
    private var content: some View {
        switch message {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the agent's last message…")
                    .lineLimit(1)
            }
            .font(.avenir(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        case .text(let text):
            LastMessageView(text: text, showsTitle: false)
        case .none:
            Text("The agent hasn't said anything yet.")
                .font(.avenir(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
    }
}
