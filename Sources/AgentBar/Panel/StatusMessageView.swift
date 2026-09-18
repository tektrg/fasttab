import SwiftUI

/// Full-panel message for every state that is not a list.
struct StatusMessageView: View {
    let state: AgentListState

    var body: some View {
        VStack(spacing: 6) {
            Text(content.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(content.isAlarm ? Color.orange : Color.primary)
            if let detail = content.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let hint = content.hint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var content: (title: String, detail: String?, hint: String?, isAlarm: Bool) {
        switch state {
        case .connecting:
            ("Connecting…", "Waiting for the first status update.", nil, false)
        case .feedDown(let reason):
            ("Status feed down", reason, "Is the chief dashboard running at 127.0.0.1:4711?", true)
        case .noAgents:
            ("No agents running", nil, nil, false)
        case .noMatches:
            ("No matches", nil, nil, false)
        case .list:
            ("", nil, nil, false)
        }
    }
}
