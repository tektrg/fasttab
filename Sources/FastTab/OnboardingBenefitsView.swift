import SwiftUI

/// One reason to act on an onboarding step (install the extension, get the
/// iPhone app). Each list lives next to the feature it sells —
/// `OnboardingExtensionBenefits.swift`, `OnboardingIPhoneStep.swift` — so the
/// claims stay true when that feature changes.
struct OnboardingBenefit: Identifiable {
    let id: String
    let symbolName: String
    let title: String
    let detail: String
}

/// Stacked benefit rows: tinted SF Symbol, bold title, one short line.
struct OnboardingBenefitsView: View {
    let benefits: [OnboardingBenefit]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(benefits) { benefit in
                OnboardingBenefitRow(benefit: benefit)
            }
        }
    }
}

private struct OnboardingBenefitRow: View {
    let benefit: OnboardingBenefit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: benefit.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(benefit.title)
                    .font(.callout.weight(.semibold))
                Text(benefit.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
