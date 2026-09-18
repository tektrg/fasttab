import SwiftUI

/// "4m" / "2h" time-in-status, re-evaluated every few seconds between refreshes.
struct AgentAgeView: View {
    let agent: AgentSnapshot
    let fetchedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(ageText(now: context.date))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func ageText(now: Date) -> String {
        AgentAge.seconds(for: agent, fetchedAt: fetchedAt, now: now).map(AgentAge.shortText) ?? ""
    }
}
