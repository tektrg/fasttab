import SwiftUI

/// Last screen: a one-line tour of the tab bar, then into the Read tab.
/// Reader-only phones have no Tabs tab, so their tour skips it and drops Mac wording.
struct OnboardingDoneStep: View {
    var isReaderOnly = false
    let onStart: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "You're set",
            message: "Here's where everything lives."
        ) {
            OnboardingHeroDone()
        } content: {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                OnboardingFeatureRow(
                    systemImage: "newspaper",
                    tint: DS.Tint.emerging,
                    title: "Read",
                    detail: isReaderOnly
                        ? "Links you saved, and the articles you're reading."
                        : "Forgotten tabs worth a second look, and the articles you're reading."
                )
                if !isReaderOnly {
                    OnboardingFeatureRow(
                        systemImage: "macwindow.on.rectangle",
                        tint: DS.Tint.action,
                        title: "Tabs",
                        detail: "Every tab open on your Mac. Search, read or close them from here."
                    )
                }
                OnboardingFeatureRow(
                    systemImage: "shuffle",
                    tint: DS.Tint.action,
                    title: "Shuffle",
                    detail: isReaderOnly
                        ? "Random cards from your saved links, for a quick rediscovery."
                        : "Random cards from your tabs and bookmarks, for a quick rediscovery."
                )
                OnboardingFeatureRow(
                    systemImage: "ellipsis.circle",
                    tint: .secondary,
                    title: "More",
                    detail: "Bookmarks, history, highlights and this guide, any time."
                )
            }
            .dsCard()
        } actions: {
            OnboardingPrimaryButton(title: "Start reading", action: onStart)
        }
    }
}
