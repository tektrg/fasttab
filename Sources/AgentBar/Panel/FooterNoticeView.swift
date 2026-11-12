import IndieCommandBar
import SwiftUI

/// A failure notice (failed switch, row action, answer or decision), drawn over the bottom of
/// the panel just above the footer, in the shared persistent error slot (`CommandBarErrorNotice`).
/// It stays until the user closes it (✕ or esc) or a newer failure replaces it.
struct FooterNoticeView: View {
    let notice: PanelFooterNotice
    let onDismiss: () -> Void

    var body: some View {
        CommandBarErrorNotice(
            text: notice.text, tint: notice.tint, textColor: notice.textColor,
            font: .avenir(size: 12, weight: .medium), closeFont: .avenir(size: 14),
            onDismiss: onDismiss
        )
    }
}
