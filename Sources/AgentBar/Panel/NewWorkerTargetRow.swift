import SwiftUI
import IndieCommandBar

/// New worker step 2's row above the search box: the chosen persona (its ✕ goes back to the folder
/// list, same as Esc) and the machine chips when it can run on 2+ machines. Fits
/// `AgentPanelMetrics.tagRowHeight`, the Tab-tag chip row's slot.
struct NewWorkerTargetRow: View {
    @Environment(\.commandBarTheme) private var theme
    let pick: PersonaPick
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("New worker in \(pick.persona.name)")
                    .font(.avenir(size: 12, weight: .semibold))
                    .lineLimit(1)
                Button(action: onBack) {
                    Image(systemName: "xmark")
                        .font(.avenir(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Pick another folder (esc)")
                .accessibilityLabel("Pick another folder")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.accentColor.opacity(0.18)))
            .overlay(Capsule().strokeBorder(theme.accentColor.opacity(0.32), lineWidth: 1))
            .fixedSize()
            PersonaMachineChips(chips: pick.machineChips, selectedID: pick.machineID)
        }
    }
}
