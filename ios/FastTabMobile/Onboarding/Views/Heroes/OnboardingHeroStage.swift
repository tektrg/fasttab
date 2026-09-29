import SwiftUI
import HeroMotion

/// Runs one onboarding hero: a fixed 180 × 120 pt canvas whose picture is a
/// pure function of time (`frame(seconds)`).
///
/// - Loops forever while the step is on screen; a one-shot holds its last frame.
/// - Reduce Motion, a backgrounded app, a step off screen, or `isSuspended`
///   (something covering the step) all stop the clock and show the rest frame.
/// - A new `replayKey` (a state change) restarts the clock and cross-fades.
/// - Decorative: hidden from VoiceOver.
/// - Drawn at `onboardingHeroScale` (smaller on short screens), laid out at that size.
struct OnboardingHeroStage<Frame: View>: View {
    static var canvasSize: CGSize { CGSize(width: 180, height: 120) }

    let playback: HeroPlayback
    var replayKey: AnyHashable = 0
    var isSuspended = false
    @ViewBuilder let frame: (Double) -> Frame

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.onboardingHeroScale) private var scale
    @State private var isOnScreen = false
    @State private var clock = HeroClock()

    /// Everything but the clock itself allows motion.
    private var canAnimate: Bool {
        !reduceMotion && isOnScreen && scenePhase == .active && !isSuspended
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: !clock.isTicking(key: replayKey, canAnimate: canAnimate))) { context in
                frame(frameTime(at: context.date))
                    .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
            }
            .id(replayKey)
            .transition(.opacity)
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .clipped()
        .scaleEffect(scale)
        .frame(width: Self.canvasSize.width * scale, height: Self.canvasSize.height * scale)
        .animation(.easeInOut(duration: 0.3), value: replayKey)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: canAnimate) { _, canAnimate in
            if canAnimate { clock.resume(playback: playback, at: Date()) }
        }
        .task(id: ClockRun(replayKey: replayKey, canAnimate: canAnimate)) { await runClock() }
        .accessibilityHidden(true)
    }

    private func frameTime(at date: Date) -> Double {
        clock.frameTime(playback: playback, key: replayKey, canAnimate: canAnimate, now: date)
    }

    /// Re-runs `runClock` when the picture changes or the stage pauses/resumes.
    private struct ClockRun: Hashable {
        let replayKey: AnyHashable
        let canAnimate: Bool
    }

    /// Restarts on appear and on every state change; marks a one-shot done
    /// once it has played in view, so the timeline stops ticking once it rests.
    /// A pause mid-beat (the app backgrounded, a sheet on top) cancels this
    /// task, so the beat replays on return: a Mac found while the user was
    /// away still plays its "found" beat.
    private func runClock() async {
        let key = replayKey
        guard let duration = clock.sync(key: key, playback: playback, canAnimate: canAnimate, at: Date()) else { return }
        try? await Task.sleep(for: .seconds(duration))
        guard !Task.isCancelled else { return }
        clock.finish(key: key)
    }
}

extension EnvironmentValues {
    /// How big onboarding heroes draw: 1 is the storyboard's 180 × 120 pt.
    @Entry var onboardingHeroScale: Double = 1
}

/// Places hero parts by their top-left corner in the 180 × 120 canvas, the
/// way the storyboard specifies them.
extension View {
    func heroPlaced(x: Double, y: Double, width: Double, height: Double) -> some View {
        frame(width: width, height: height)
            .position(x: x + width / 2, y: y + height / 2)
    }
}
