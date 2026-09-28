import SwiftUI

/// The top line of a card: which agent (name, project) and the Copy button.
struct AgentCardHeader: View {
    let label: String
    let projectName: String?
    let agentID: String
    /// The agent whose details were just copied (for the "Copied" feedback), and the copy action.
    var copiedAgentID: String?
    var onCopy: () -> Void = {}
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let projectName {
                Text(projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            OpenAgentButton(onOpen: onOpen)
            CopyIdentityButton(isCopied: copiedAgentID == agentID, showsLabel: true, onCopy: onCopy)
        }
        .padding(.horizontal, 18)
        .frame(height: AgentPanelMetrics.answerHeaderHeight)
    }
}
