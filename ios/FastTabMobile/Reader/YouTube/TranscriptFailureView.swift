import SwiftUI

/// Shown instead of the reader when a YouTube transcript can't be loaded.
struct TranscriptFailureView: View {
    let message: String
    let videoURL: URL

    var body: some View {
        VStack(spacing: DS.Space.md) {
            Image(systemName: "captions.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button {
                UIApplication.shared.open(videoURL)
            } label: {
                Label("Open in YouTube", systemImage: "play.rectangle")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(DS.Space.lg)
    }
}
