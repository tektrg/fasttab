import SwiftUI

/// Runs one onboarding hero: a fixed 180 × 120 pt canvas whose picture is a
/// pure function of time (`frame(seconds)`).
///
/// - Loops forever while the step is on screen; a one-shot holds its last frame.
/// - Reduce Motion, a backgrounded app, a step off screen, or `isSuspended`
///   (something covering the step) all stop the clock and show the rest frame.
/// - A new `replayKey` (a state change) restarts the clock and cross-fades.
/// - Decorative: hidden from VoiceOver.
struct OnboardingHeroStage<Frame: View>: View {
    static var canvasSize: CGSize { CGSize(width: 180, height: 120) }

    let playback: HeroPlayback
    var replayKey: AnyHashable = 0
    var isSuspended = false
    @ViewBuilder let frame: (Double) -> Frame

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    /// When the clock last (re)started, and for which `replayKey`.
    @State private var clockStart: (key: AnyHashable, date: Date)?
    @State private var finishedKey: AnyHashable?

    private var isPlaying: Bool {
        !reduceMotion && isOnScreen && scenePhase == .active && !isSuspended
            && clockStart?.key == replayKey && finishedKey != replayKey
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: !isPlaying)) { context in
                frame(frameTime(at: context.date))
                    .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
            }
            .id(replayKey)
            .transition(.opacity)
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: replayKey)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .task(id: replayKey) { await runClock() }
        .accessibilityHidden(true)
    }

    private func frameTime(at date: Date) -> Double {
        guard isPlaying, let clockStart else { return playback.restTime }
        return playback.frameTime(elapsed: date.timeIntervalSince(clockStart.date))
    }

    /// Restarts on appear and on every state change; marks a one-shot done so
    /// the timeline stops ticking once it rests.
    private func runClock() async {
        let key = replayKey
        clockStart = (key, Date())
        guard let duration = playback.oneShotDuration else { return }
        try? await Task.sleep(for: .seconds(duration))
        guard !Task.isCancelled else { return }
        finishedKey = key
    }
}

/// Places hero parts by their top-left corner in the 180 × 120 canvas, the
/// way the storyboard specifies them.
extension View {
    func heroPlaced(x: Double, y: Double, width: Double, height: Double) -> some View {
        frame(width: width, height: height)
            .position(x: x + width / 2, y: y + height / 2)
    }
}
