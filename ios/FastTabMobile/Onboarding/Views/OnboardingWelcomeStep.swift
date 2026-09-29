import SwiftUI

/// Screen 1: what the app is for. Benefit wording mirrors the Mac app's
/// iPhone onboarding step (`OnboardingBenefit.iPhoneBenefits` in
/// `Sources/FastTab/OnboardingIPhoneStep.swift`) so both apps promise the same things.
struct OnboardingWelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Your Mac's tabs, in your pocket",
            message: "FastTab brings the tabs and bookmarks from your Mac to your iPhone."
        ) {
            OnboardingHeroWelcome()
        } content: {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                OnboardingFeatureRow(
                    systemImage: "arrow.uturn.backward.circle.fill",
                    tint: DS.Tint.emerging,
                    title: "Revisit forgotten tabs",
                    detail: "Resurfaces old bookmarks and tabs left open for days. Or shuffle through all your links."
                )
                OnboardingFeatureRow(
                    systemImage: "doc.plaintext.fill",
                    tint: DS.Tint.recent,
                    title: "Reader mode",
                    detail: "Open articles from your tabs as clean text. Highlight passages, pick up where you left off."
                )
                OnboardingFeatureRow(
                    systemImage: "paperplane.fill",
                    tint: DS.Tint.shared,
                    title: "Send links to your Mac",
                    detail: "Share a link on iPhone and your Mac opens it, right away or when it wakes."
                )
            }
            .dsCard()
        } actions: {
            OnboardingPrimaryButton(title: "Get started", action: onContinue)
        }
    }
}
