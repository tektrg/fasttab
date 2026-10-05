import Foundation
import IndieFeedback
import IndieFeedbackUI

/// Fast Tab's "Chat with the Creator" on theindie-api: a Settings sidebar row and a menu-bar item.
/// Anonymous: Fast Tab has no portfolio account yet, so no push; the app polls (launch, activation,
/// every 5 min) and `center.hasNews` drives the red dot on the menu-bar icon, the menu item and the
/// Settings row. The install secret lives in the Keychain.
enum FastTabFeedback {
    /// Optional server override (`defaults write <bundle id> FastTab.feedbackServerURL http://…`);
    /// otherwise `FeedbackServer` decides (local dev server until feedback is live in production).
    static let serverOverrideDefaultsKey = "FastTab.feedbackServerURL"
    /// Keep stable once shipped: groups this install's messages on the server.
    static let installIDDefaultsKey = "FastTab.feedbackInstallID"

    static func makeConfiguration() -> FeedbackConfiguration {
        FeedbackConfiguration(
            appSlug: "fasttab",
            baseURL: FeedbackServer.baseURL(overrideDefaultsKey: serverOverrideDefaultsKey),
            installIDDefaultsKey: installIDDefaultsKey
        )
    }

    static func makeClient() -> FeedbackClient {
        FeedbackClient(configuration: makeConfiguration())
    }

    /// The single source of every "something new from the creator" dot.
    @MainActor static let center = FeedbackCenter(configuration: makeConfiguration())

    /// The standalone chat window (menu bar item, new-release auto-open).
    @MainActor static let chatWindow = FeedbackChatWindowController(center: center)

    static let menuTitle = "Chat with the Creator"
    static let symbolName = "bubble.left.and.bubble.right"

    /// Call once at launch: start polling, and open the chat on a first launch of a new release.
    @MainActor static func start() {
        center.startPolling()
        guard !OnboardingWindowController.shared.isNeeded else { return }
        Task { await chatWindow.presentOnNewRelease() }
    }
}
