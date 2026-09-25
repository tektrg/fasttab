import SwiftUI

/// Strip at the bottom of the panel, always present: key hints (or, in their
/// place, the orange shortcut-problem notice) and the settings button. Failure
/// notices are not drawn here but as `FooterNoticeView` above it. Height is `AgentPanelMetrics.footerHeight`.
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
        .background(stripNotice?.tint.opacity(0.12) ?? Color.clear)
    }

    @ViewBuilder
    private var message: some View {
        if let stripNotice {
            Text(stripNotice.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(stripNotice.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(stripNotice.text)
        } else {
            Text(PanelFooterHints.text(for: hintContext))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    /// Only the non-closable notice lives in the strip.
    private var stripNotice: PanelFooterNotice? {
        notice.flatMap { $0.isDismissible ? nil : $0 }
    }
}

extension PanelFooterNotice {
    var tint: Color {
        switch self {
        case .switchFailed, .actionFailed: .red
        case .hotkeyUnavailable, .warning: .orange
        case .created: .green
        }
    }

    /// The notice's words: the tint is a fill, and plain orange is too faint as small text.
    var textColor: Color {
        switch self {
        case .switchFailed, .actionFailed: .red
        case .hotkeyUnavailable, .warning: WarningTextColor.color
        case .created: .green
        }
    }
}
