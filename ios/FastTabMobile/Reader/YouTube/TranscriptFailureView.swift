import IndieAccount
import SwiftUI

/// Shown instead of the reader when a YouTube transcript can't be loaded.
struct TranscriptFailureView: View {
    /// What the view offers besides "Open in YouTube".
    enum Action: Equatable {
        /// No account yet: Sign in with Apple, then the reader loads again by itself.
        case signIn
        /// Trying again could help (network, rate limit).
        case retry
        /// A permanent no.
        case none

        init(_ failure: TranscriptReaderError) {
            switch failure {
            case .needsAccount: self = .signIn
            case .unavailable: self = .retry
            case .noTranscript, .needsSignIn: self = .none
            }
        }
    }

    let failure: TranscriptReaderError
    let videoURL: URL
    /// Loads the transcript again; also runs after a successful sign-in.
    let retry: () -> Void

    @Environment(AccountSession.self) private var accountSession: AccountSession?

    var body: some View {
        VStack(spacing: DS.Space.md) {
            Image(systemName: "captions.bubble")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(failure.localizedDescription)
                .font(.headline)
                .multilineTextAlignment(.center)
            switch Action(failure) {
            case .signIn:
                if accountSession != nil {
                    AppleSignInButton(onSignedIn: retry)
                        .frame(maxWidth: 320)
                    if let message = accountSession?.lastError?.userMessage {
                        Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
            case .retry:
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
            case .none:
                EmptyView()
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
