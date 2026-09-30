import SwiftUI
import IndieMotion

/// Runs one onboarding hero: IndieMotion's `MotionStage` on the fixed
/// 180 × 120 pt storyboard canvas, drawn at `onboardingHeroScale` (smaller on
/// short screens). The stage owns the pause rules (Reduce Motion, backgrounded
/// app, step off screen, `isSuspended` for something covering the step), the
/// `replayKey` cross-fade and the one-shot beat: a Mac found while the user was
/// away still plays its "found" beat on return.
struct OnboardingHeroStage<Frame: View>: View {
    static var canvasSize: CGSize { CGSize(width: 180, height: 120) }

    let playback: MotionPlayback
    var replayKey: AnyHashable = 0
    var isSuspended = false
    @ViewBuilder let frame: (Double) -> Frame

    @Environment(\.onboardingHeroScale) private var scale

    var body: some View {
        MotionStage(
            canvasSize: Self.canvasSize,
            scale: scale,
            playback: playback,
            replayKey: replayKey,
            isSuspended: isSuspended,
            frame: frame
        )
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
        motionPlaced(x: x, y: y, width: width, height: height)
    }
}
