import SwiftUI

/// The newest routed message a row is still holding (see `AgentPanelModel.routedNotesByAgentID`).
/// Same shape as `UnpushedBadgeView` — a small capsule that fits the row's fixed height, older
/// notes riding along as a "+N" and the tooltip; the ✕ is the only way one goes away.
struct RoutedNoteBadgeView: View {
    let notes: [RoutedNote]
    var onClear: (UUID) -> Void = { _ in }

    var body: some View {
        if let newest = notes.first {
            HStack(spacing: 4) {
                Text("📌 \(newest.text)")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if notes.count > 1 {
                    Text("+\(notes.count - 1)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Button { onClear(newest.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .frame(maxWidth: 160, alignment: .trailing)
            .help(notes.map(\.text).joined(separator: "\n\n"))
        }
    }
}
