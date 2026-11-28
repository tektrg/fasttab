import SwiftUI

/// A Desktop chief's check-in badge ("Next 16:07", "Overdue 40m", "Check-in running") on its row.
/// Clicking it opens a menu: last / next check-in, the schedule, the pace (rush / steady / pace out
/// / quiet) and the sleep-time check-ins toggle. Words come from `ChiefCheckInText` (pure, tested);
/// changes go to `AgentTreeModel.updateChiefCheckIn`, which the dashboard persists.
struct ChiefCheckInBadge: View {
    let checkIn: ChiefCheckIn
    let now: Date
    var onChange: (_ pace: ChiefCheckInPace?, _ sleepCheckins: Bool?) -> Void = { _, _ in }

    var body: some View {
        let badge = ChiefCheckInText.badge(checkIn, now: now)
        Menu {
            ForEach(ChiefCheckInText.detailLines(checkIn, now: now), id: \.self) { line in
                Text(line)
            }
            Divider()
            Picker("Pace", selection: Binding(get: { checkIn.pace }, set: { onChange($0, nil) })) {
                ForEach(ChiefCheckInPace.allCases, id: \.self) { pace in
                    Text("\(pace.title) — \(pace.detail)").tag(pace)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Check-ins during sleep hours", isOn: Binding(get: { checkIn.sleepCheckins }, set: { onChange(nil, $0) }))
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "clock")
                Text(badge.text)
            }
            .font(.avenir(size: 10, weight: .semibold))
            .foregroundStyle(color(badge.tone))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chief check-ins: last, next, pace")
        .accessibilityLabel("Chief check-in: \(badge.text)")
    }

    private func color(_ tone: ChiefCheckInText.Tone) -> Color {
        switch tone {
        case .ok: .green
        case .warn: .orange
        case .danger: .red
        case .muted: .secondary
        }
    }
}
