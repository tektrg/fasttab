import AppKit
import SwiftUI
import HeroMotion

/// Runs one Mac onboarding hero: a fixed 200 × 96 pt canvas whose picture is
/// a pure function of time (`frame(seconds)`). The Mac twin of the iPhone's
/// `ios/FastTabMobile/Onboarding/Views/Heroes/OnboardingHeroStage.swift`;
/// both share the clock in `HeroMotion`.
///
/// - Loops forever while the step is on screen; a one-shot holds its last frame.
/// - Reduce Motion, the step off screen, the onboarding window not key (or the
///   app inactive), or the window covered all stop the clock and show the rest frame.
/// - A new `replayKey` (a state change) restarts the clock and cross-fades.
/// - Decorative: hidden from VoiceOver.
/// - Drawn at `onboardingHeroScale` (half size in the compact window), laid out at that size.
struct OnboardingHeroStage<Frame: View>: View {

    let playback: HeroPlayback
    var replayKey: AnyHashable = 0
    @ViewBuilder let frame: (Double) -> Frame

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `.key` only while the onboarding window is key in the active app.
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.onboardingHeroScale) private var scale
    @State private var isOnScreen = false
    @State private var isWindowVisible = true
    @State private var clock = HeroClock()

    private var canAnimate: Bool {
        !reduceMotion && isOnScreen && controlActiveState == .key && isWindowVisible
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: !clock.isTicking(key: replayKey, canAnimate: canAnimate))) { context in
                frame(clock.frameTime(playback: playback, key: replayKey, canAnimate: canAnimate, now: context.date))
                    .frame(width: HeroCanvas.size.width, height: HeroCanvas.size.height)
            }
            .id(replayKey)
            .transition(.opacity)
        }
        .frame(width: HeroCanvas.size.width, height: HeroCanvas.size.height)
        .clipped()
        .scaleEffect(scale)
        .frame(width: HeroCanvas.size.width * scale, height: HeroCanvas.size.height * scale)
        .animation(.easeInOut(duration: 0.3), value: replayKey)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: canAnimate) { _, canAnimate in
            if canAnimate { clock.resume(playback: playback, at: Date()) }
        }
        // Only matters while this window is key, and then it is `NSApp.keyWindow`.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            isWindowVisible = NSApp.keyWindow?.occlusionState.contains(.visible) ?? true
        }
        .task(id: ClockRun(replayKey: replayKey, canAnimate: canAnimate)) { await runClock() }
        .accessibilityHidden(true)
    }

    /// Re-runs `runClock` when the picture changes or the stage pauses/resumes.
    private struct ClockRun: Hashable {
        let replayKey: AnyHashable
        let canAnimate: Bool
    }

    /// Restarts on appear and on every state change; marks a one-shot done
    /// once it has played in view, so the timeline stops ticking once it rests.
    /// A pause mid-beat cancels this task, so the beat replays on return.
    private func runClock() async {
        let key = replayKey
        guard let duration = clock.sync(key: key, playback: playback, canAnimate: canAnimate, at: Date()) else { return }
        try? await Task.sleep(for: .seconds(duration))
        guard !Task.isCancelled else { return }
        clock.finish(key: key)
    }
}

extension EnvironmentValues {
    /// How big onboarding heroes draw: 1 is the storyboard's 200 × 96 pt.
    /// Set from `OnboardingLayout.heroScale`.
    @Entry var onboardingHeroScale: Double = 1
}

enum HeroCanvas {
    /// Every Mac hero draws into this, per the storyboard.
    static let size = CGSize(width: 200, height: 96)
}

/// Places hero parts by their top-left corner in the 200 × 96 canvas, the
/// way the storyboard specifies them.
extension View {
    func heroPlaced(x: Double, y: Double, width: Double, height: Double) -> some View {
        frame(width: width, height: height)
            .position(x: x + width / 2, y: y + height / 2)
    }
}
