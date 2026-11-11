import SwiftUI

struct SectionHeaderView: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.avenir(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: AgentPanelMetrics.headerHeight, alignment: .bottom)
    }
}
