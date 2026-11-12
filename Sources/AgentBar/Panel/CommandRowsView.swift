import SwiftUI
import IndieCommandBar

/// Slash-command rows (`AgentPanelModel.commandRows`) in place of the agent list while the search
/// box starts with "/". Hover highlights, click runs (same as Return).
struct CommandRowsView: View {
    @ObservedObject var model: AgentPanelModel

    var body: some View {
        let highlighted = model.highlightedCommand?.id
        VStack(spacing: 0) {
            ForEach(model.commandRows) { command in
                CommandRow(command: command, isSelected: command.id == highlighted)
                    .onHover { inside in
                        if inside { model.highlightCommand(id: command.id) }
                    }
                    .onTapGesture { model.run(command) }
            }
        }
        .padding(.vertical, AgentPanelMetrics.listVerticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct CommandRow: View {
    @Environment(\.commandBarTheme) private var theme
    let command: CommandBarCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(command.title)
                .font(.avenir(size: 13, weight: .semibold))
            Text(command.trigger)
                .font(.avenir(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: AgentPanelMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? theme.accentColor.opacity(0.22) : .clear))
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
