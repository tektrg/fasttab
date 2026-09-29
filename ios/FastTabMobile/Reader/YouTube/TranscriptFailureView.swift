import SwiftUI

/// Shown instead of the reader when a YouTube transcript can't be loaded.
struct TranscriptFailureView: View {
    let message: String
    let videoURL: URL
    /// Offered when trying again could help (network, rate limit); nil for a permanent no.
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.Space.md) {
            Image(systemName: "captions.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
            }
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
