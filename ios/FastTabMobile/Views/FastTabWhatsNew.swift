import IndieFeedback
import IndieFeedbackUI
import IndieWhatsNew
import StoreKit
import SwiftUI

/// FastTab's "What's New → review" (IndieLibKit `IndieWhatsNew`, portfolio standard 2026-11-14).
/// Replaces the old after-browser-close rating popup: after a release the owner flagged big on
/// theindie-api, returning users get a dismissible card at the top of Read. Tap → the release
/// notes → Apple's stars, "Send feedback" (the creator chat) under them. Never a pop-up.
@MainActor
enum FastTabWhatsNew {
    /// FastTab Reader on the App Store, for "Write a review".
    static let appStoreID = "6828689539"
    static let text = WhatsNewText(appName: "FastTab")
    /// Keep stable once shipped. `ratingPromptState` is the old popup's state: its cooldown carries over.
    static let storage = WhatsNewStorage(keyPrefix: "fasttab", ratingStateKey: "ratingPromptState")
    /// This iPhone's anonymous feedback thread (the Mac app has its own).
    static let feedbackInstallIDKey = "fasttab.ios.feedbackInstallID"

    static var feedbackConfiguration: FeedbackConfiguration {
        FeedbackConfiguration(account: .fastTab, installIDDefaultsKey: feedbackInstallIDKey)
    }

    /// One per app run.
    static let model: WhatsNewModel = {
        let model = WhatsNewModel(configuration: feedbackConfiguration, storage: storage)
        #if DEBUG
        // `-FastTabWhatsNewSample YES`: a sample card (stores nothing), for screenshots and checks.
        if UserDefaults.standard.bool(forKey: "FastTabWhatsNewSample") { showSampleCard() }
        #endif
        return model
    }()

    /// Call at launch, before the guide can finish: finished onboarding, or the old rating popup's
    /// launch record (every earlier build wrote it), means a returning user.
    static func noteLaunch() {
        let returning = OnboardingCompletionStore().isCompleted || UserDefaults.standard.string(forKey: storage.ratingStateKey) != nil
        model.noteLaunch(isReturningUser: returning)
    }

    #if DEBUG
    static func showSampleCard() {
        model.previewCard(ReleaseNote(version: model.appVersion, notes: """
        - **Read Aloud** with a natural voice
        - Highlights grid with tag filters
        """, publishedAt: 0, isBig: true))
    }
    #endif
}

/// The What's New card for the top of Read, with its flow sheet. Empty when there is no card.
struct WhatsNewCardSlot: View {
    @State private var whatsNew = FastTabWhatsNew.model
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // A stack, not a Group: an empty Group is no view, so its .task would never run.
        VStack(spacing: 0) {
            if let note = whatsNew.cardNote {
                WhatsNewCard(note: note, text: FastTabWhatsNew.text,
                             style: WhatsNewCardStyle(accent: DS.Tint.action),
                             onOpen: { Task { await whatsNew.openCard() } },
                             onDismiss: { whatsNew.dismissCard() })
                    .padding(.horizontal).padding(.vertical, 6)
                    .background(.bar)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: whatsNew.cardNote)
        .task { await whatsNew.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await whatsNew.refresh() }
        }
        .whatsNewFlow(model: whatsNew, text: FastTabWhatsNew.text, appStoreID: FastTabWhatsNew.appStoreID,
                      requestReview: { requestReview() }) {
            FastTabFeedbackChat()
        }
    }
}

/// This iPhone's creator chat: "Send feedback" on the review step and More > Chat with the Creator.
struct FastTabFeedbackChat: View {
    var body: some View {
        FeedbackChatView(client: FeedbackClient(configuration: FastTabWhatsNew.feedbackConfiguration))
            .navigationTitle("Chat with the Creator")
            .navigationBarTitleDisplayMode(.inline)
    }
}
