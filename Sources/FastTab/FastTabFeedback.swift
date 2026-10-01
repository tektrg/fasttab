import Foundation
import IndieFeedback

/// Fast Tab's in-app feedback (Settings > About > Send Feedback…) to theindie-api.
/// Anonymous: Fast Tab has no portfolio account yet.
enum FastTabFeedback {
    /// Optional server override (`defaults write <bundle id> FastTab.feedbackServerURL http://…`);
    /// otherwise `FeedbackServer` decides (local dev server until feedback is live in production).
    static let serverOverrideDefaultsKey = "FastTab.feedbackServerURL"
    /// Keep stable once shipped: groups this install's messages on the server.
    static let installIDDefaultsKey = "FastTab.feedbackInstallID"

    static func makeClient() -> FeedbackClient {
        FeedbackClient(configuration: FeedbackConfiguration(
            appSlug: "fasttab",
            baseURL: FeedbackServer.baseURL(overrideDefaultsKey: serverOverrideDefaultsKey),
            installIDDefaultsKey: installIDDefaultsKey
        ))
    }
}
