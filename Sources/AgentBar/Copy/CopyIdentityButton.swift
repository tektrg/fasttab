import SwiftUI

/// A small "copy this agent's name and pane ID" button. After a copy the icon turns into a
/// check (and, with `showsLabel`, a "Copied" label appears) and fades back on its own.
struct CopyIdentityButton: View {
    let isCopied: Bool
    var showsLabel = false
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if showsLabel {
                Text("Copied")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .opacity(isCopied ? 1 : 0)
            }
            Button(action: onCopy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(isCopied ? Color.green : .secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy agent name, pane ID and folder")
            .accessibilityLabel("Copy agent details")
        }
        .animation(.easeOut(duration: 0.35), value: isCopied)
    }
}
