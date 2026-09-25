import SwiftUI

/// "Air" for a node/agent running on the `air-m1` machine; nothing is shown for `local` (the badge
/// is simply omitted). Was `Tree/AgentTreeRowView.swift`'s `MachineBadgeView`, moved here once the
/// separate Agent Hierarchy window was folded into the main list — the merged list still carries
/// this rule ("Air agents keep the Air tag").
struct MachineBadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .foregroundStyle(.secondary)
    }
}
