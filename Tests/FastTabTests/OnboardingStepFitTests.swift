import AppKit
import CommandBarKit
import SwiftUI
import Testing
@testable import FastTab

/// Measures an onboarding step the way the window lays it out: full width,
/// as short as its content allows (the steps pad with flexible spacers).
@MainActor
enum OnboardingStepFit {
    static func fittingHeight(of step: some View) -> CGFloat {
        let host = NSHostingView(rootView: step.frame(width: OnboardingLayout.windowSize.width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Stores backed by a throwaway defaults suite, so tests never read or
    /// write the real app's settings.
    static func scratchDefaults(_ values: [String: Any] = [:]) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "OnboardingStepFitTests.\(UUID().uuidString)")!
        values.forEach { defaults.set($0.value, forKey: $0.key) }
        return defaults
    }

    static func sourceStore(enabled: [SearchSource]) -> SourceSelectionStore {
        SourceSelectionStore(defaults: scratchDefaults([
            "FastTab.enabledSources.v1": enabled.map(\.rawValue),
            "FastTab.enabledSources.v1.seeded": true,
        ]))
    }
}

/// The onboarding window is a fixed size (`OnboardingLayout.windowSize`) and
/// each step now carries a 200 × 96 hero, so every step, in each of its
/// states, must fit `OnboardingLayout.stepHeight` or its bottom gets clipped.
/// The iPhone step is covered by `OnboardingIPhoneStepTests`.
@MainActor
struct OnboardingStepFitTests {
    private let budget = OnboardingLayout.stepHeight

    @Test func welcomeFits() {
        let height = OnboardingStepFit.fittingHeight(of: WelcomeStep(onContinue: {}))
        #expect(height <= budget, "welcome step is \(height)pt tall")
    }

    @Test(arguments: EdgeRevealStyle.allCases)
    func triggerStyleFits(style: EdgeRevealStyle) {
        let store = EdgeRevealStore(defaults: OnboardingStepFit.scratchDefaults(["FastTab.edgeReveal.style": style.rawValue]))
        #expect(store.style == style)
        let height = OnboardingStepFit.fittingHeight(of: TriggerStyleStep(edgeReveal: store, onContinue: {}))
        #expect(height <= budget, "trigger step (\(style)) is \(height)pt tall")
    }

    /// All sources on (every row), and none (adds the "select one" note).
    @Test(arguments: [SearchSource.allCases, []])
    func sourcePickerFits(enabled: [SearchSource]) {
        let store = OnboardingStepFit.sourceStore(enabled: enabled)
        #expect(store.enabled == Set(enabled))
        let height = OnboardingStepFit.fittingHeight(of: SourcePickerStep(store: store, onContinue: {}))
        #expect(height <= budget, "source step (\(enabled.count) on) is \(height)pt tall")
    }

    /// Measured while waiting for the extension (the test host has none). After
    /// 15s of waiting the status view adds a two-line "not connecting" hint, so
    /// leave room for it.
    @Test func extensionStepFitsWithRoomForTheNotConnectingHint() {
        let notConnectingHintHeight: CGFloat = 36
        let height = OnboardingStepFit.fittingHeight(of: ExtensionInstallStep(
            didAutoAdvance: .constant(true), onContinue: {}, onAutoAdvance: {}
        ))
        #expect(height + notConnectingHintHeight <= budget, "extension step is \(height)pt tall")
    }

    /// Worst case: access granted during onboarding, which adds the
    /// "restarts when you finish" row. Hosted in a window so `onAppear` and
    /// the app-activation check run.
    @Test func safariStepFitsAfterAGrant() {
        var checks = 0
        let step = SafariPermissionStep(onContinue: {}, canReadSafariProtectedData: {
            checks += 1
            return checks > 1
        })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: OnboardingLayout.windowSize), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: step.frame(width: OnboardingLayout.windowSize.width))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        #expect(checks >= 2, "the step re-checked access on activation")
        #expect(height <= budget, "granted Safari step is \(height)pt tall")
        window.contentView = nil
    }

    /// Worst case: the restart note shows.
    @Test func shortcutStepFits() {
        let height = OnboardingStepFit.fittingHeight(of: ShortcutStep(onDismiss: { _ in }, isRestartNeeded: { true }))
        #expect(height <= budget, "shortcut step is \(height)pt tall")
    }
}
