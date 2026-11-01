import SwiftUI
import FastTabSync

/// Organize-mode row accessory: compact folder chip + "Bookmark" button.
/// Saving and the "Also close this tab?" offer are the list's job, so this
/// row accessory behaves exactly like the swipe / long-press save actions.
struct TabFolderRecommendationChip: View {
    let recommendation: TabFolderRecommendation
    let onBookmark: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            Label(recommendation.folderName, systemImage: "folder")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.xxs)
                .background(DS.Tint.action.opacity(0.12), in: Capsule())
                .foregroundStyle(DS.Tint.action)
                .accessibilityLabel("Suggested folder \(recommendation.folderName)")

            Button("Bookmark", action: onBookmark)
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
        }
    }
}
