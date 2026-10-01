import SwiftUI

/// The persona confirm row's machine choice, e.g. `[Pro] [Air]` — the selected one filled
/// (`PersonaPick.machineChips` / `machineID`; Left/Right move it). Sized to the 20pt routing row
/// (`AgentPanelMetrics.routingRowHeight`): never taller, so the panel's fixed height budget holds.
struct PersonaMachineChips: View {
    let chips: [PersonaMachine]
    let selectedID: String?

    var body: some View {
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(chips, id: \.id) { chip in
                    let isSelected = chip.id == selectedID
                    Text(chip.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 16)
                        .background(Capsule().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .fixedSize()
        }
    }
}
