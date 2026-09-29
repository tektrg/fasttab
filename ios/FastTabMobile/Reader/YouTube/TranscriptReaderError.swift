import Foundation
import IndieTranscripts
import os

/// What the reader tells the person when a transcript can't be shown. The failure view
/// pairs the message with an "Open in YouTube" button.
enum TranscriptReaderError: LocalizedError, Equatable {
    case noTranscript
    case needsSignIn
    /// No theindie account token on this phone: the failure view offers Sign in with Apple.
    case needsAccount
    case unavailable

    private static let log = Logger(subsystem: "app.theindie.FastTabMobile", category: "transcript")

    init(_ error: Error) {
        switch error as? TranscriptError {
        case .noCaptions?: self = .noTranscript
        case .loginRequired?: self = .needsSignIn
        case .notSignedIn?: self = .needsAccount
        default: self = .unavailable
        }
        if self != .noTranscript {
            Self.log.error("transcript failed: \(String(describing: error), privacy: .public)")
        }
    }

    var errorDescription: String? {
        switch self {
        case .noTranscript: return "No transcript for this video"
        case .needsSignIn: return "This video needs sign-in on YouTube"
        case .needsAccount: return "Sign in to get transcripts"
        case .unavailable: return "Couldn't load the transcript"
        }
    }
}
