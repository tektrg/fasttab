import SwiftUI

/// One-line strip at the bottom of the panel; red for a failed switch,
/// orange for a shortcut problem. Height is `AgentPanelMetrics.footerHeight`.
struct FooterNoticeView: View {
    let notice: PanelFooterNotice

    var body: some View {
        Text(notice.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isError ? Color.red : Color.orange)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: AgentPanelMetrics.footerHeight)
            .background((isError ? Color.red : Color.orange).opacity(0.12))
            .help(notice.text)
    }

    private var isError: Bool {
        if case .switchFailed = notice { return true }
        return false
    }
}
