import SwiftUI
import IndieMotion

/// Step 7: the user's own shortcut keys press in order, a ripple spreads
/// from them and the command bar pops up above. Recording a new shortcut
/// replays it with the new keys. Loops while the step is on screen.
struct OnboardingHeroShortcut: View {
    let keycaps: [String]

    var body: some View {
        OnboardingHeroStage(playback: ShortcutHeroKeycaps.playback, replayKey: keycaps) { time in
            Self.frame(keycaps: keycaps, time: time)
        }
    }

    static func frame(keycaps: [String], time: Double) -> some View {
        HeroShortcutPress(
            keycaps: keycaps,
            time: time,
            barFrame: CGRect(x: 40, y: 5, width: 120, height: 52),
            keysCenter: CGPoint(x: HeroCanvas.size.width / 2, y: 74),
            keysMaxWidth: HeroCanvas.size.width - 8,
            showsRipple: true
        )
    }
}

/// Keycaps pressing one after another, then a command bar popping open.
/// Shared by the shortcut hero and the trigger hero's "hovering off" picture.
struct HeroShortcutPress: View {
    let keycaps: [String]
    let time: Double
    /// Where the bar sits once open, in the parent's coordinates.
    let barFrame: CGRect
    let keysCenter: CGPoint
    /// The keys shrink to fit this; wider rows would be clipped.
    let keysMaxWidth: Double
    var showsRipple = false

    private var playback: MotionPlayback { ShortcutHeroKeycaps.playback }
    private var popTime: Double { ShortcutHeroKeycaps.barPopTime(keyCount: keycaps.count) }
    private var releaseTime: Double { popTime + ShortcutHeroKeycaps.releaseDelay }

    var body: some View {
        let fade = MotionCurve.loopFade(time, playback: playback)
        let pop = MotionCurve.progress(time, start: popTime + 0.1, duration: 0.55, ease: .bouncy)
        ZStack(alignment: .topLeading) {
            HeroCommandBar(rowCount: 2)
                .scaleEffect(MotionCurve.lerp(0.6, 1, pop), anchor: .bottom)
                .opacity(min(pop * 2, 1) * fade)
                .heroPlaced(in: barFrame)
            if showsRipple {
                ripple.opacity(fade)
            }
            HeroKeycapRow(keycaps: keycaps, maxWidth: keysMaxWidth, press: press(ofKeyAt:))
                .position(keysCenter)
        }
    }

    private func press(ofKeyAt index: Int) -> Double {
        let down = ShortcutHeroKeycaps.firstPressTime + Double(index) * ShortcutHeroKeycaps.pressStagger
        return MotionCurve.progress(time, start: down, duration: 0.08)
            - MotionCurve.progress(time, start: releaseTime, duration: ShortcutHeroKeycaps.releaseDuration)
    }

    private var ripple: some View {
        let spread = MotionCurve.progress(time, start: popTime, duration: 0.6, ease: .easeOut)
        return Capsule()
            .strokeBorder(HeroInk.accent.ink, lineWidth: 2)
            .frame(width: MotionCurve.lerp(48, 130, spread), height: MotionCurve.lerp(24, 44, spread))
            .opacity(spread > 0 && spread < 1 ? 1 - spread : 0)
            .position(keysCenter)
    }
}
