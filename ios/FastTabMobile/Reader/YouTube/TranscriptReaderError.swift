import Foundation
import IndieTranscripts

/// What the reader tells the person when a transcript can't be shown. The failure view
/// pairs the message with an "Open in YouTube" button.
enum TranscriptReaderError: LocalizedError, Equatable {
    case noTranscript
    case needsSignIn
    case unavailable

    init(_ error: Error) {
        switch error as? TranscriptError {
        case .noCaptions?: self = .noTranscript
        case .loginRequired?: self = .needsSignIn
        default: self = .unavailable
        }
    }

    var errorDescription: String? {
        switch self {
        case .noTranscript: return "No transcript for this video"
        case .needsSignIn: return "This video needs sign-in on YouTube"
        case .unavailable: return "Couldn't load the transcript"
        }
    }
}
