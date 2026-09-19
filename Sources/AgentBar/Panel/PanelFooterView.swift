import SwiftUI

/// Strip at the bottom of the panel, always present: key hints (or, in their
/// place, a red failed-switch/action or orange shortcut-problem notice) and
/// the settings button. Height is `AgentPanelMetrics.footerHeight`.
struct PanelFooterView: View {
    let notice: PanelFooterNotice?
    var hintContext = PanelFooterHints.Context()
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            message
            Spacer(minLength: 0)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            .accessibilityLabel("Open Settings")
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .frame(height: AgentPanelMetrics.footerHeight)
        .background(noticeColor?.opacity(0.12) ?? Color.clear)
    }

    @ViewBuilder
    private var message: some View {
        if let notice {
            Text(notice.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(noticeColor ?? .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(notice.text)
        } else {
            Text(PanelFooterHints.text(for: hintContext))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private var noticeColor: Color? {
        switch notice {
        case .switchFailed, .actionFailed: .red
        case .hotkeyUnavailable: .orange
        case nil: nil
        }
    }
}
