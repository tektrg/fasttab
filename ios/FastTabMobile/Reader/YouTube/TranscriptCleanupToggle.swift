import SwiftUI

/// Reader bar button: Clean ↔ Original transcript. While paragraphs are still being cleaned
/// (Clean view), a small spinner rides on the icon; the text stays readable throughout.
struct TranscriptCleanupToggle: View {
    @ObservedObject var cleanup: TranscriptCleanupSession

    var body: some View {
        Button {
            cleanup.setShowsClean(!cleanup.showsClean)
        } label: {
            Image(systemName: cleanup.showsClean ? "wand.and.sparkles" : "text.alignleft")
                .font(.body)
                .overlay(alignment: .topTrailing) {
                    if cleanup.showsClean && cleanup.isCleaning {
                        ProgressView()
                            .controlSize(.mini)
                            .offset(x: 8, y: -8)
                            .accessibilityHidden(true)
                    }
                }
                .readerBarTapTarget()
        }
        .accessibilityLabel(cleanup.showsClean ? "Show original transcript" : "Show cleaned transcript")
        .accessibilityValue(cleanup.showsClean && cleanup.isCleaning ? "Cleaning up" : "")
    }
}
