import SwiftUI

/// First screen of the guide: "Do you use FastTab on your Mac?"
///
/// The answer sets the `AppMode` and the rest of the guide
/// (`OnboardingRoute.path(for:)`). It can be changed later in More.
struct OnboardingForkStep: View {
    let onChoose: (AppMode) -> Void

    var body: some View {
        OnboardingStepLayout(title: "Do you use FastTab on your Mac?") {
            OnboardingHeroWelcome()
        } content: {
            VStack(spacing: DS.Space.md) {
                choiceButton(
                    mode: .mac,
                    title: "Yes",
                    detail: "See your Mac's tabs here and send links to it.",
                    systemImage: "macbook.and.iphone"
                )
                choiceButton(
                    mode: .standalone,
                    title: "No",
                    detail: "Use FastTab on its own to save links and read them later.",
                    systemImage: "iphone"
                )
            }
        } actions: {
            Text("You can change this later in More.")
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
        }
    }

    private func choiceButton(mode: AppMode, title: String, detail: String, systemImage: String) -> some View {
        Button {
            onChoose(mode)
        } label: {
            HStack(spacing: DS.Space.md) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(DS.Tint.action)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(title)
                        .font(DS.Font.sectionTitle)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(DS.Font.meta)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .dsCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(detail)
    }
}
