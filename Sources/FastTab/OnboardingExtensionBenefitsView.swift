import SwiftUI

/// One reason to install the companion extension, shown on the onboarding
/// extension step. Each claim maps to real extension-only behavior — keep
/// them true when the extension changes:
/// - `recents`: `ExtensionBackedBackend` feeds exact `chrome.tabs.onActivated`
///   times into the recency store; without it `BrowserTabService` polls the
///   active tab every 10s.
/// - `instant`: tabs are served from the bridge's live snapshot, no per-open
///   browser round-trip.
/// - `playing`: only the extension reports `audible`/`muted`, which drives the
///   sticky playing tab and the mute toggle.
/// - `private`: tab switching skips the macOS Automation prompt; the bridge is
///   a local Unix socket, nothing leaves the Mac.
struct OnboardingExtensionBenefit: Identifiable {
    let id: String
    let symbolName: String
    let title: String
    let detail: String

    static let all: [OnboardingExtensionBenefit] = [
        .init(
            id: "recents",
            symbolName: "clock.arrow.circlepath",
            title: "Recents in true order",
            detail: "Catches every tab switch as it happens, instead of checking every few seconds."
        ),
        .init(
            id: "instant",
            symbolName: "bolt.fill",
            title: "Instant tab list",
            detail: "Your tabs are ready the moment FastTab opens."
        ),
        .init(
            id: "playing",
            symbolName: "speaker.wave.2.fill",
            title: "Playing tabs stay on top",
            detail: "Find the tab making sound in a glance, and mute it in one click."
        ),
        .init(
            id: "private",
            symbolName: "lock.shield.fill",
            title: "No permission pop-up",
            detail: "Skips the macOS prompt. Everything stays on your Mac."
        ),
    ]
}

/// Stacked benefit rows: tinted SF Symbol, bold title, one short line.
struct OnboardingExtensionBenefitsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(OnboardingExtensionBenefit.all) { benefit in
                OnboardingExtensionBenefitRow(benefit: benefit)
            }
        }
    }
}

private struct OnboardingExtensionBenefitRow: View {
    let benefit: OnboardingExtensionBenefit

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
