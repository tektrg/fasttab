import IndieAccount
import SwiftUI

/// Last screen: everything is free; Premium is optional. "Start free trial" opens the existing
/// paywall as a sheet, "Maybe later" just continues. Nothing here blocks entering the app.
/// Wording: `PremiumWording`.
struct OnboardingPremiumStep: View {
    let onContinue: () -> Void

    @Environment(AccountSession.self) private var accountSession
    @State private var pricing = NaturalVoicePricing.loading
    @State private var showsPaywall = false

    var body: some View {
        OnboardingStepLayout(
            title: PremiumWording.onboardingTitle,
            message: PremiumWording.onboardingMessage
        ) {
            OnboardingHeroDone()
        } content: {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                Text(PremiumWording.onboardingOffer(pricing: pricing))
                    .font(DS.Font.body)
                    .fixedSize(horizontal: false, vertical: true)
                OnboardingFeatureRow(systemImage: "waveform", tint: DS.Tint.action,
                                     title: "Natural Voice",
                                     detail: "Listen to articles in natural voices, in languages other than English.")
                OnboardingFeatureRow(systemImage: "sparkles", tint: DS.Tint.emerging,
                                     title: "AI Summary",
                                     detail: "The gist of any article in seconds.")
            }
            .dsCard()
        } actions: {
            OnboardingPrimaryButton(title: PremiumWording.onboardingStartTitle(pricing: pricing)) { showsPaywall = true }
            OnboardingSecondaryButton(title: "Maybe later", action: onContinue)
        }
        .task { pricing = await NaturalVoicePricing.load() }
        .sheet(isPresented: $showsPaywall) {
            NaturalVoicePaywallView { onContinue() }.environment(accountSession)
        }
    }
}
