import SwiftUI

/// The peek (Space on a row, 2026-11-14 redesign): agent header with two tabs — **Last message**
/// (default, the whole transcript message, scrolls) and **Terminal** (the raw pane read, mono,
/// read-only) — switched by a click, Tab, or ←/→ (`PeekKeyRouting`); a message box that sends on both tabs (the Tab-tag
/// compose path, `AgentPanelModel.sendFromPeek`); and the shared `AgentActionRow`. Fills exactly
/// `bodyHeight`, the height of the list it replaces.
struct PanePeekView: View {
    @ObservedObject var model: AgentPanelModel
    let peek: PanePeek
    let bodyHeight: CGFloat
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    static let inputRowHeight: CGFloat = 44
    static let actionRowHeight: CGFloat = 38

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                switch peek.tab {
                case .lastMessage: lastMessage
                case .terminal: terminal
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            input
            actions
        }
        .frame(height: bodyHeight)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(peek.label)
                .font(.avenir(size: 14, weight: .semibold))
                .lineLimit(1)
            if let project = peek.projectName {
                Text(project)
                    .font(.avenir(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            tabs
        }
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.peekHeaderHeight)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(PanePeek.Tab.allCases, id: \.self) { tab in
                Button { model.selectPeekTab(tab) } label: {
                    Text(tab.title)
                        .font(.avenir(size: 12, weight: peek.tab == tab ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .foregroundStyle(peek.tab == tab ? Color.primary : Color.secondary)
                        .background(Capsule().fill(peek.tab == tab ? Color.primary.opacity(0.12) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(tab.title) (Tab or ←/→ switches)")
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .fixedSize()
    }

    @ViewBuilder
    private var lastMessage: some View {
        switch peek.message {
        case .latestMessage(let text):
            ScrollView {
                MarkdownBlocksView(blocks: MarkdownParser.parse(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18).padding(.vertical, 10)
            }
        case .unavailable(let reason): centered { Text(reason).multilineTextAlignment(.center) }
        default: centered { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading latest message…") } }
        }
    }

    @ViewBuilder
    private var terminal: some View {
        switch peek.content {
        case .loading:
            centered { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading screen…") } }
        case .unavailable(let reason):
            centered { Text(reason).multilineTextAlignment(.center) }
        case .screen(let lines, let readAt):
            VStack(spacing: 0) {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.avenirMono(size: 11))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(height: AgentPanelMetrics.peekTextLineHeight, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, AgentPanelMetrics.peekTextVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottomLeading)
                .background(Color.primary.opacity(0.05))
                HStack {
                    Text("Read at \(readAt.formatted(.dateTime.hour().minute().second())) · read-only")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.avenir(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .frame(height: AgentPanelMetrics.peekReadLineHeight)
            }
        case .loadingLatestMessage, .latestMessage:
            centered { Text(PanePeek.noTerminalMessage).multilineTextAlignment(.center) }
        }
    }

    private var input: some View {
        let refusal = model.peekMessageRefusal
        return HStack(spacing: 8) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary)
            TextField(refusal ?? "Message \(peek.label)…", text: $draft)
                .textFieldStyle(.plain)
                .font(.avenir(size: 13))
                .lineLimit(1)
                .disabled(refusal != nil)
                .onSubmit { if model.sendFromPeek(draft) { draft = "" } }
                .onExitCommand { model.closePeek() }
                .focused($inputFocused)
                .onChange(of: inputFocused) { _, focused in model.peekInputFocused = focused }
                .onDisappear { model.peekInputFocused = false }
            if let sending = model.peekAgent.flatMap({ model.sendingLabel(for: $0) ?? model.sentLabel(for: $0) }) {
                Text(sending).font(.avenir(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: Self.inputRowHeight)
    }

    @ViewBuilder
    private var actions: some View {
        if let agent = model.peekAgent {
            AgentActionRow(
                items: AgentActionList.items(for: agent, tree: model.treeModel.tree, hiding: [.peek, .message]),
                actionState: model.rowActionStates[agent.id],
                onAction: { action in
                    switch action {
                    case .close: model.closePeek()
                    case .goToAgent: model.openPeekAgent()
                    case .row(let button): model.press(button, on: agent.id)
                    }
                }
            )
            .padding(.horizontal, 18)
            .frame(height: Self.actionRowHeight)
        }
    }

    private func centered<Message: View>(@ViewBuilder _ message: () -> Message) -> some View {
        message()
            .font(.avenir(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
