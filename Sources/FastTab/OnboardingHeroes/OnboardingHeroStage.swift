import SwiftUI
import IndieMotion

/// Runs one Mac onboarding hero: IndieMotion's `MotionStage` on the fixed
/// 200 × 96 pt storyboard canvas, drawn at `onboardingHeroScale` (half size in
/// the compact window). The stage owns the pause rules (Reduce Motion, off
/// screen, window not key or covered), the `replayKey` cross-fade and the
/// one-shot beat. The iPhone twin is
/// `ios/FastTabMobile/Onboarding/Views/Heroes/OnboardingHeroStage.swift`.
struct OnboardingHeroStage<Frame: View>: View {

    let playback: MotionPlayback
    var replayKey: AnyHashable = 0
    @ViewBuilder let frame: (Double) -> Frame

    @Environment(\.onboardingHeroScale) private var scale

    var body: some View {
        MotionStage(canvasSize: HeroCanvas.size, scale: scale, playback: playback, replayKey: replayKey, frame: frame)
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
        motionPlaced(x: x, y: y, width: width, height: height)
    }

    func heroPlaced(in rect: CGRect) -> some View {
        motionPlaced(in: rect)
    }
}
