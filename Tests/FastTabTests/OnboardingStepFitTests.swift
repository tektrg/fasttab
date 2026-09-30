import AppKit
import CommandBarKit
import IndieEdgeReveal
import SwiftUI
import Testing
@testable import FastTab

/// Measures an onboarding step the way the window lays it out: full width,
/// heroes at the layout's scale, as short as its content allows (the steps
/// pad with flexible spacers).
@MainActor
enum OnboardingStepFit {
    static func fittingHeight(of step: some View, in layout: OnboardingLayout) -> CGFloat {
        let host = NSHostingView(rootView: sized(step, in: layout))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    static func sized(_ step: some View, in layout: OnboardingLayout) -> some View {
        step
            .environment(\.onboardingHeroScale, layout.heroScale)
            .frame(width: layout.windowSize.width)
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

/// The onboarding window is a fixed size (`OnboardingLayout`, regular or
/// compact) and each step carries an animated hero, so every step, in each of
/// its states and in both layouts, must fit `stepHeight` or its bottom gets
/// clipped. The iPhone step is covered by `OnboardingIPhoneStepTests`.
@MainActor
struct OnboardingStepFitTests {
    @Test(arguments: OnboardingLayout.all)
    func welcomeFits(layout: OnboardingLayout) {
        let height = OnboardingStepFit.fittingHeight(of: WelcomeStep(onContinue: {}), in: layout)
        #expect(height <= layout.stepHeight, "welcome step is \(height)pt tall")
    }

    @Test(arguments: OnboardingLayout.all, EdgeRevealStyle.allCases)
    func triggerStyleFits(layout: OnboardingLayout, style: EdgeRevealStyle) {
        let store = EdgeRevealStore(defaults: OnboardingStepFit.scratchDefaults(["FastTab.edgeReveal.style": style.rawValue]))
        #expect(store.style == style)
        let height = OnboardingStepFit.fittingHeight(of: TriggerStyleStep(edgeReveal: store, onContinue: {}), in: layout)
        #expect(height <= layout.stepHeight, "trigger step (\(style)) is \(height)pt tall")
    }

    /// All sources on (every row), and none (adds the "select one" note).
    @Test(arguments: OnboardingLayout.all, [SearchSource.allCases, []])
    func sourcePickerFits(layout: OnboardingLayout, enabled: [SearchSource]) {
        let store = OnboardingStepFit.sourceStore(enabled: enabled)
        #expect(store.enabled == Set(enabled))
        let height = OnboardingStepFit.fittingHeight(of: SourcePickerStep(store: store, onContinue: {}), in: layout)
        #expect(height <= layout.stepHeight, "source step (\(enabled.count) on) is \(height)pt tall")
    }

    /// Measured while waiting for the extension (the test host has none). After
    /// 15s of waiting the status view adds a two-line "not connecting" hint, so
    /// leave room for it.
    @Test(arguments: OnboardingLayout.all)
    func extensionStepFitsWithRoomForTheNotConnectingHint(layout: OnboardingLayout) {
        let notConnectingHintHeight: CGFloat = 36
        let height = OnboardingStepFit.fittingHeight(of: ExtensionInstallStep(
            didAutoAdvance: .constant(true), onContinue: {}, onAutoAdvance: {}
        ), in: layout)
        #expect(height + notConnectingHintHeight <= layout.stepHeight, "extension step is \(height)pt tall")
    }

    /// Worst case: access granted during onboarding, which adds the
    /// "restarts when you finish" row. Hosted in a window so `onAppear` and
    /// the app-activation check run.
    @Test(arguments: OnboardingLayout.all)
    func safariStepFitsAfterAGrant(layout: OnboardingLayout) {
        var checks = 0
        let step = SafariPermissionStep(onContinue: {}, canReadSafariProtectedData: {
            checks += 1
            return checks > 1
        })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: layout.windowSize), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: OnboardingStepFit.sized(step, in: layout))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        host.layoutSubtreeIfNeeded()
        let height = host.fittingSize.height
        #expect(checks >= 2, "the step re-checked access on activation")
        #expect(height <= layout.stepHeight, "granted Safari step is \(height)pt tall")
        window.contentView = nil
    }

    /// Worst case: the restart note shows.
    @Test(arguments: OnboardingLayout.all)
    func shortcutStepFits(layout: OnboardingLayout) {
        let height = OnboardingStepFit.fittingHeight(of: ShortcutStep(onDismiss: { _ in }, isRestartNeeded: { true }), in: layout)
        #expect(height <= layout.stepHeight, "shortcut step is \(height)pt tall")
    }
}

/// Which window size a screen gets: the tall one only when it clears the
/// screen's usable area (menu bar and Dock excluded) with a margin.
struct OnboardingLayoutChoiceTests {
    @Test func tallScreensGetTheRegularWindow() {
        #expect(OnboardingLayout.fitting(visibleScreenHeight: 875) == .regular)
        #expect(OnboardingLayout.fitting(visibleScreenHeight: OnboardingLayout.regular.windowSize.height + OnboardingLayout.screenMargin) == .regular)
    }

    /// 13" Macs at "Larger Text" scaling with the Dock showing.
    @Test func shortScreensGetTheCompactWindow() {
        #expect(OnboardingLayout.fitting(visibleScreenHeight: OnboardingLayout.regular.windowSize.height + OnboardingLayout.screenMargin - 1) == .compact)
        #expect(OnboardingLayout.fitting(visibleScreenHeight: 556) == .compact)
    }

    @Test func theCompactWindowFitsTheSmallestSupportedScreen() {
        let smallestVisibleHeight: CGFloat = 556
        #expect(OnboardingLayout.compact.windowSize.height + OnboardingLayout.screenMargin <= smallestVisibleHeight)
        #expect(OnboardingLayout.compact.windowSize.width == OnboardingLayout.regular.windowSize.width)
    }
}
