import SwiftUI

/// Screen 5: a one-line tour of the tab bar, then into the Read tab.
struct OnboardingDoneStep: View {
    let onStart: () -> Void

    var body: some View {
        OnboardingStepLayout(
            systemImage: "checkmark.circle.fill",
            tint: DS.Tint.success,
            title: "You're set",
            message: "Here's where everything lives."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                OnboardingFeatureRow(
                    systemImage: "newspaper",
                    tint: DS.Tint.emerging,
                    title: "Read",
                    detail: "Forgotten tabs worth a second look, and the articles you're reading."
                )
                OnboardingFeatureRow(
                    systemImage: "macwindow.on.rectangle",
                    tint: DS.Tint.action,
                    title: "Tabs",
                    detail: "Every tab open on your Mac. Search, read or close them from here."
                )
                OnboardingFeatureRow(
                    systemImage: "shuffle",
                    tint: DS.Tint.action,
                    title: "Shuffle",
                    detail: "Random cards from your tabs and bookmarks, for a quick rediscovery."
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
