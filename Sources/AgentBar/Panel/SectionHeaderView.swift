import SwiftUI

struct SectionHeaderView: View {
    let section: AgentSection

    var body: some View {
        Text(section.title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: AgentPanelMetrics.headerHeight, alignment: .bottom)
    }
}
