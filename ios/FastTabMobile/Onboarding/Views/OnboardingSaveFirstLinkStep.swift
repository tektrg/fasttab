import SwiftUI
import FastTabSync

/// Reader-only path, screen 1: put FastTab in the share sheet, then save a first link.
///
/// "Try it" saves the sample article through the same store the share sheet's
/// "Save to iPhone" fills (`SavedOnIPhoneStore`), so it shows up under FastTab List on Read.
struct OnboardingSaveFirstLinkStep: View {
    /// One-screen sheet from an empty state: the button says Done.
    let isSingleStep: Bool
    let onContinue: () -> Void

    @ObservedObject private var savedStore = SavedOnIPhoneStore.shared

    private var hasSavedSample: Bool {
        savedStore.items.contains { $0.url == ReaderSampleArticle.url.absoluteString }
    }

    var body: some View {
        OnboardingStepLayout(
            title: "Save links to read later",
            message: "Add FastTab to your share sheet once. Then any link is one tap from your reading list."
        ) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 72))
                .foregroundStyle(DS.Tint.recent)
                .padding(.vertical, DS.Space.xl)
                .accessibilityHidden(true)
        } content: {
            VStack(spacing: DS.Space.lg) {
                OnboardingShareSheetInstructions()

                Text("Then pick FastTab and choose Save to FastTab List.")
                    .font(DS.Font.meta)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                tryItSection
            }
        } actions: {
            OnboardingPrimaryButton(title: isSingleStep ? "Done" : "Continue", action: onContinue)
        }
    }

    @ViewBuilder
    private var tryItSection: some View {
        if hasSavedSample {
            Label("Saved — it's waiting on the Read tab", systemImage: "checkmark.circle.fill")
                .font(DS.Font.cardTitle)
                .foregroundStyle(DS.Tint.success)
        } else {
            Button(action: saveSampleLink) {
                Label("Try it: save a sample article", systemImage: "bookmark")
            }
            .buttonStyle(.dsTinted(DS.Tint.recent))
        }
    }

    private func saveSampleLink() {
        savedStore.add([SavedOnIPhoneLink(url: ReaderSampleArticle.url.absoluteString, title: ReaderSampleArticle.title)])
    }
}
