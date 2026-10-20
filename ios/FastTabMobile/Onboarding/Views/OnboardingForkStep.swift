import SwiftUI

/// First screen of the guide: a welcome that leans toward reading on its own.
///
/// "Continue" picks reader-only (`AppMode.standalone`); the quiet
/// "Have FastTab on your Mac?" link picks `.mac`. The answer sets the rest of
/// the guide (`OnboardingRoute.path(for:)`) and can be changed later in More.
struct OnboardingForkStep: View {
    let onChoose: (AppMode) -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Welcome to your reading journey",
            message: "Save links to read later, highlight, and revisit any time. Everything is saved privately in your iCloud."
        ) {
            OnboardingHeroReading()
        } content: {
            VStack(spacing: DS.Space.xxs) {
                Text("“The more that you read, the more things you will know.”")
                    .font(DS.Font.meta)
                    .italic()
                    .multilineTextAlignment(.center)
                Text("— Dr. Seuss")
                    .font(DS.Font.meta)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
        } actions: {
            OnboardingPrimaryButton(title: "Continue") { onChoose(.standalone) }
            OnboardingSecondaryButton(title: "Have FastTab on your Mac?") { onChoose(.mac) }
        }
    }
}
