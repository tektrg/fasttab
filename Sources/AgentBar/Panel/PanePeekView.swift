import SwiftUI

/// The peek body: agent header, the pane's screen text (read-only, clipped to
/// the panel, newest lines at the bottom) and a "read at" line. Fills exactly
/// `bodyHeight`, the height of the list it replaces.
struct PanePeekView: View {
    let peek: PanePeek
    let bodyHeight: CGFloat
    var onOpen: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            readLine
        }
        .frame(height: bodyHeight)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(peek.label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let project = peek.projectName {
                Text(project)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            OpenAgentButton(onOpen: onOpen)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.peekHeaderHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch peek.content {
        case .loading:
            centered { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading screen…") } }
        case .unavailable(let reason):
            centered { Text(reason).multilineTextAlignment(.center) }
        case .screen(let lines, _):
            screenText(lines)
        case .loadingLatestMessage:
            centered { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading latest message…") } }
        case .latestMessage(let text):
            ScrollView { LastMessageView(text: text).padding(.horizontal, 18).padding(.vertical, 8) }
        }
    }

    private func screenText(_ lines: [String]) -> some View {
        let visibleCount = AgentPanelMetrics.peekVisibleLineCount(bodyHeight: bodyHeight)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.suffix(visibleCount).enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: AgentPanelMetrics.peekTextLineHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, AgentPanelMetrics.peekTextVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(Color.primary.opacity(0.05))
        .clipped()
    }

    private func centered<Message: View>(@ViewBuilder _ message: () -> Message) -> some View {
        message()
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readLine: some View {
        HStack {
            if case .screen(_, let readAt) = peek.content {
                Text("Read at \(readAt.formatted(.dateTime.hour().minute().second())) · read-only")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.peekReadLineHeight)
    }
}
