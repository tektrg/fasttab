import SwiftUI
import HeroMotion

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
            barFrame: CGRect(x: 50, y: 2, width: 100, height: 50),
            keysCenter: CGPoint(x: 100, y: 74),
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
    var showsRipple = false

    private var playback: HeroPlayback { ShortcutHeroKeycaps.playback }
    private var popTime: Double { ShortcutHeroKeycaps.barPopTime(keyCount: keycaps.count) }
    private var releaseTime: Double { popTime + ShortcutHeroKeycaps.releaseDelay }

    var body: some View {
        let fade = HeroCurve.loopFade(time, playback: playback)
        let pop = HeroCurve.progress(time, start: popTime + 0.1, duration: 0.4, ease: .spring)
        ZStack(alignment: .topLeading) {
            HeroCommandBar(rowCount: 2)
                .scaleEffect(HeroCurve.lerp(0.6, 1, pop), anchor: .bottom)
                .opacity(min(pop * 2, 1) * fade)
                .heroPlaced(x: barFrame.minX, y: barFrame.minY, width: barFrame.width, height: barFrame.height)
            if showsRipple {
                ripple.opacity(fade)
            }
            HeroKeycapRow(keycaps: keycaps, press: press(ofKeyAt:))
                .position(keysCenter)
        }
    }

    private func press(ofKeyAt index: Int) -> Double {
        let down = ShortcutHeroKeycaps.firstPressTime + Double(index) * ShortcutHeroKeycaps.pressStagger
        return HeroCurve.progress(time, start: down, duration: 0.08)
            - HeroCurve.progress(time, start: releaseTime, duration: ShortcutHeroKeycaps.releaseDuration)
    }

    private var ripple: some View {
        let spread = HeroCurve.progress(time, start: popTime, duration: 0.6, ease: .easeOut)
        return Capsule()
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .frame(width: HeroCurve.lerp(40, 110, spread), height: HeroCurve.lerp(20, 40, spread))
            .opacity(spread > 0 && spread < 1 ? 1 - spread : 0)
            .position(keysCenter)
    }
}
