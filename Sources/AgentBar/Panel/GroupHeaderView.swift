import SwiftUI

/// A project (or "Unassigned") header in the grouped hierarchy area — same look as
/// `SectionHeaderView`, a different data source (`AgentGroupHeader`, not `AgentSection`).
struct GroupHeaderView: View {
    let header: AgentGroupHeader

    var body: some View {
        Text(header.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: AgentPanelMetrics.headerHeight, alignment: .bottom)
    }
}
