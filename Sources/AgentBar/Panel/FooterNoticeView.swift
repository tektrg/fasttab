import SwiftUI

/// A failure notice (failed switch, row action, answer or decision), drawn over the bottom of
/// the panel just above the footer. It stays until the user closes it (✕ or esc) or a newer
/// failure replaces it. Long text wraps, and scrolls past `maxTextHeight`; it is selectable so
/// the wording can be copied. Drawn over the body, so the window's height does not depend on it.
struct FooterNoticeView: View {
    let notice: PanelFooterNotice
    let onDismiss: () -> Void
    @State private var textHeight: CGFloat = 16

    /// About five lines of text; more scrolls.
    static let maxTextHeight: CGFloat = 80

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // An invisible copy measures the text; the visible one scrolls only past `maxTextHeight`.
            ZStack(alignment: .top) {
                text.hidden().accessibilityHidden(true).onContentHeightChange { textHeight = $0 }
                ScrollView { text }.scrollBounceBehavior(.basedOnSize)
            }
            .frame(height: min(textHeight, Self.maxTextHeight))
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss (esc)")
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .overlay(notice.tint.opacity(0.12))
        .overlay(alignment: .top) { Divider() }
    }

    private var text: some View {
        Text(notice.text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(notice.tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
