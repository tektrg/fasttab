import SwiftUI

/// Focus mode's LEFT panel: what the agent did and said. The recap whole (the feed's squeezed one
/// is put back by `RecapExpander`), then the agent's last message (always shown, as markdown).
/// No local transcript (agent on the other Mac, not Claude): the dashboard text, labelled
/// "Limited context". "What it did" (tool steps) is slice 3.
struct FocusContextView: View {
    let agent: AgentSnapshot
    /// Nil while the transcript is read.
    let context: FocusContext?

    var body: some View {
        FocusFittedPanel { fit in
            VStack(alignment: .leading, spacing: fit.body * 1.1) {
                if context?.hasTranscript == false {
                    Text("Limited context — no transcript on this Mac")
                        .font(.avenir(size: fit.body * 0.6, weight: .semibold))
                        .foregroundStyle(FocusPalette.mute)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(FocusPalette.line))
                }
                section(Self.statusTitle(agent.statusText), fit: fit) {
                    Text(Self.statusBody(agent.statusText))
                        .font(.avenir(size: fit.body))
                        .foregroundStyle(FocusPalette.ink)
                        .lineSpacing(fit.body * 0.25)
                }
                lastMessage(fit: fit)
            }
            .textSelection(.enabled)
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private func lastMessage(fit: FocusTextFit) -> some View {
        switch context {
        case nil:
            section("Last message", fit: fit) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the agent's last message…")
                }
                .font(.avenir(size: fit.body * 0.7))
                .foregroundStyle(FocusPalette.mute)
            }
        case let context?:
            if let text = context.lastMessage {
                section("Last message", fit: fit) {
                    MarkdownBlocksView(blocks: MarkdownParser.parse(String(text.prefix(20_000))), bodySize: fit.body)
                        .foregroundStyle(FocusPalette.ink)
                }
            }
        }
    }

    private func section<Body: View>(_ title: String, fit: FocusTextFit, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: fit.body * 0.4) {
            Text(title.uppercased())
                .font(.avenir(size: max(11, fit.body * 0.55), weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(FocusPalette.mute)
            body()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func statusTitle(_ statusText: String) -> String {
        statusText.hasPrefix(RecapText.prefix) ? "Recap" : "Status"
    }

    static func statusBody(_ statusText: String) -> String {
        guard statusText.hasPrefix(RecapText.prefix) else { return statusText }
        return statusText.dropFirst(RecapText.prefix.count).trimmingCharacters(in: .whitespaces)
    }
}
