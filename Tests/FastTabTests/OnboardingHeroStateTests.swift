import AppKit
import CommandBarKit
import HeroMotion
import Testing
@testable import FastTab

/// Which picture each Mac onboarding hero shows for its step's live state,
/// and how each picture's clock runs.
struct OnboardingHeroStateTests {
    // MARK: - Trigger style

    @Test func triggerFollowsTheChosenHotSpot() {
        let keys = ["⌥", "Space"]
        #expect(TriggerHeroState(style: .notch, shortcutKeycaps: keys) == .hover(.notch))
        #expect(TriggerHeroState(style: .leftEdge, shortcutKeycaps: keys) == .hover(.leftEdge))
        #expect(TriggerHeroState(style: .rightEdge, shortcutKeycaps: keys) == .hover(.rightEdge))
    }

    @Test func hoveringOffShowsTheUsersShortcut() {
        #expect(TriggerHeroState(style: .off, shortcutKeycaps: ["⌘", "K"]) == .keyboard(keycaps: ["⌘", "K"]))
    }

    // MARK: - Sources

    @Test func sourcesKeepThePickerOrder() {
        let state = SourcesHeroState(enabled: [.finder, .chrome, .safari])
        #expect(state.enabledSources == [.chrome, .safari, .finder])
        #expect(state.isEnabled(.chrome))
        #expect(!state.isEnabled(.edge))
    }

    /// A toggle changes the state, which is what replays the stream.
    @Test func togglingASourceChangesThePicture() {
        #expect(SourcesHeroState(enabled: [.chrome]) != SourcesHeroState(enabled: [.chrome, .edge]))
    }

    // MARK: - Extension

    @Test func extensionTeachesUntilUsable() {
        #expect(ExtensionHeroState(setupState: .waiting) == .teaching)
        #expect(ExtensionHeroState(setupState: .turnedOff) == .teaching)
        #expect(ExtensionHeroState(setupState: .versionMismatch) == .teaching)
        #expect(ExtensionHeroState(setupState: .usable) == .connected)
        #expect(ExtensionHeroState.teaching.playback.oneShotDuration == nil)
    }

    /// The step auto-advances once connected; it must not leave before the
    /// success beat has played.
    @Test func autoAdvanceWaitsForTheSuccessBeat() throws {
        let beat = try #require(ExtensionHeroState.connected.playback.oneShotDuration)
        let delay = ExtensionHeroState.autoAdvanceDelay
        #expect(delay > .milliseconds(Int(beat * 1000)))
        #expect(delay <= .seconds(2), "don't hold the user long")
    }

    // MARK: - Safari, iPhone

    @Test func safariAndIPhonePlayOnceOnSuccess() {
        #expect(SafariHeroState(isGranted: false) == .teaching)
        #expect(SafariHeroState(isGranted: true) == .granted)
        #expect(SafariHeroState.teaching.playback.oneShotDuration == nil)
        #expect(SafariHeroState.granted.playback.oneShotDuration != nil)
        #expect(IPhoneHeroState(isPhoneConnected: false) == .teaching)
        #expect(IPhoneHeroState(isPhoneConnected: true) == .connected)
        #expect(IPhoneHeroState.teaching.playback.oneShotDuration == nil)
        #expect(IPhoneHeroState.connected.playback.oneShotDuration != nil)
    }

    // MARK: - Shortcut keycaps

    @Test func keycapsSplitModifiersInMenuOrder() {
        #expect(ShortcutHeroKeycaps.keycaps(modifiers: [.command, .shift], keyName: "K") == ["⇧", "⌘", "K"])
        #expect(ShortcutHeroKeycaps.keycaps(modifiers: .option, keyName: "Space") == ["⌥", "Space"])
        #expect(ShortcutHeroKeycaps.keycaps(modifiers: .control, keyName: "") == ["⌃"])
    }

    @Test func barPopsAfterTheLastKey() {
        let lastKeyDown = ShortcutHeroKeycaps.firstPressTime + 2 * ShortcutHeroKeycaps.pressStagger
        #expect(ShortcutHeroKeycaps.barPopTime(keyCount: 3) > lastKeyDown)
    }

    // MARK: - Rest frames

    private static let everyPlayback: [HeroPlayback] = [
        WelcomeHero.playback,
        TriggerHeroState.hover(.notch).playback,
        TriggerHeroState.keyboard(keycaps: ["⌘", "Space"]).playback,
        SourcesHeroState(enabled: [.chrome]).playback,
        ExtensionHeroState.teaching.playback,
        ExtensionHeroState.connected.playback,
        SafariHeroState.teaching.playback,
        SafariHeroState.granted.playback,
        IPhoneHeroState.teaching.playback,
        IPhoneHeroState.connected.playback,
        ShortcutHeroKeycaps.playback,
    ]

    /// Reduce Motion shows the rest frame: it must sit inside the loop and
    /// outside the fade at its seam, or the still picture is half-faded.
    @Test(arguments: everyPlayback)
    func restFrameIsFullyVisible(playback: HeroPlayback) {
        #expect(HeroCurve.loopFade(playback.restTime, playback: playback) == 1, "\(playback)")
        if case .loop(let period, let restAt) = playback {
            #expect(restAt >= 0 && restAt < period)
        }
    }

    /// The shortcut's release beat must finish before the loop's rest frame,
    /// even for a five-key shortcut (⌃⌥⇧⌘ + key), so the still frame shows keys released.
    @Test func longestShortcutReleasesBeforeRest() {
        #expect(ShortcutHeroKeycaps.releaseEndTime(keyCount: 5) <= ShortcutHeroKeycaps.playback.restTime)
    }
}
