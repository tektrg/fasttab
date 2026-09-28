import Foundation

/// Reasons to install the companion extension, shown on the onboarding
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
extension OnboardingBenefit {
    static let extensionBenefits: [OnboardingBenefit] = [
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
