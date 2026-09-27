import SwiftUI

/// Where people get the FastTab iPhone companion (`ios/FastTabMobile`).
/// `nil` until it has a public App Store or TestFlight link — the onboarding
/// card then shows "Coming soon" instead of a download action.
enum FastTabIPhoneApp {
    static let downloadURL: URL? = nil
}

/// Compact card on the last onboarding step introducing the iPhone app.
/// A card rather than its own step: the flow already has up to six steps, and
/// the app can't be downloaded yet, so a whole step would be friction.
struct OnboardingIPhoneCard: View {
    var downloadURL: URL? = FastTabIPhoneApp.downloadURL

    private static let benefits: [(symbolName: String, text: String)] = [
        ("macwindow.on.rectangle", "See, search and close your Mac's tabs"),
        ("paperplane.fill", "Send a link from iPhone to open on your Mac"),
        ("icloud.fill", "Syncs over iCloud — use the same Apple Account"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.benefits, id: \.text) { benefit in
                    Label(benefit.text, systemImage: benefit.symbolName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .labelStyle(OnboardingIPhoneBenefitLabelStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("FastTab for iPhone")
                    .font(.callout.weight(.semibold))
                Text("Your Mac's tabs, in your pocket.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            downloadAction
        }
    }

    @ViewBuilder
    private var downloadAction: some View {
        if let downloadURL {
            Link("Get it on iPhone", destination: downloadURL)
                .font(.caption.weight(.semibold))
        } else {
            Text("Coming soon")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .accessibilityLabel("iPhone app coming soon")
        }
    }
}

/// Small fixed-width icon column so benefit lines align.
private struct OnboardingIPhoneBenefitLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: 16)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
