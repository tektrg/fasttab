import SwiftUI

struct AgentRowView: View {
    let agent: AgentSnapshot
    let isSelected: Bool
    let fetchedAt: Date

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agent.section.dotColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                titleLine
                detailLine
            }
        }
        .padding(.horizontal, 12)
        .frame(height: AgentPanelMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.22) : .clear))
        .padding(.horizontal, 10)
        .opacity(dimming)
        .contentShape(Rectangle())
    }

    private var titleLine: some View {
        HStack(spacing: 8) {
            Text(agent.label)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let project = agent.projectName {
                Text(project)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AgentAgeView(agent: agent, fetchedAt: fetchedAt)
        }
    }

    private var detailLine: some View {
        HStack(spacing: 8) {
            Text(agent.statusText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if agent.hasUnpushedCommits {
                UnpushedBadgeView(detail: agent.unpushedText)
            }
        }
    }

    /// Ended rows are clearly out of play; non-Claude panes are a shade quieter
    /// because their status is only a guess.
    private var dimming: Double {
        if agent.section == .ended { return 0.45 }
        return agent.hasHookData ? 1 : 0.7
    }
}
