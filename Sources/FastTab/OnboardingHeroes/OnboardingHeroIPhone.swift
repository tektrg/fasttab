import SwiftUI
import IndieMotion

/// Step 6: a tab card lifts off the Mac, arcs over iCloud to the iPhone and
/// becomes a clean (teal) Reader page; then a (blue) paperplane flies back
/// to the Mac (loops). Once an iPhone has checked in: a link line draws
/// between the two and a green check bounces (plays once).
struct OnboardingHeroIPhone: View {
    let state: IPhoneHeroState

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state) { time in
            Self.frame(state: state, time: time)
        }
    }

    private enum Layout {
        static let macScreen = CGRect(x: 4, y: 20, width: 80, height: 50)
        static let macBase = CGRect(x: 0, y: 70, width: 88, height: 6)
        static let phone = CGRect(x: 148, y: 4, width: 44, height: 88)
        static let cloud = CGRect(x: 99, y: 2, width: 30, height: 22)
        static let cardSize = CGSize(width: 30, height: 23)
        static let flightControl = CGPoint(x: 113, y: -12)
        static let linkStart = CGPoint(x: 88, y: 46)
        static let linkEnd = CGPoint(x: 146, y: 46)
        static let linkControl = CGPoint(x: 117, y: 24)
        static let checkCenter = CGPoint(x: 117, y: 36)
    }

    private struct Beats {
        var lift = 0.0
        var flight = 0.0
        var settle = 0.0
        var planeFlight = 0.0
        var macGlow = 0.0
        var link = 0.0
        var check = 0.0
        /// The phone's bounce as the card lands on it.
        var phoneLanding = 0.0
        var fade = 1.0

        init(state: IPhoneHeroState, time: Double) {
            switch state {
            case .teaching:
                lift = MotionCurve.progress(time, start: 0.3, duration: 0.4, ease: .spring)
                flight = MotionCurve.progress(time, start: 0.7, duration: 0.9)
                settle = MotionCurve.progress(time, start: 1.6, duration: 0.4)
                planeFlight = MotionCurve.progress(time, start: 2.1, duration: 0.6)
                macGlow = MotionCurve.progress(time, start: 2.65, duration: 0.2)
                phoneLanding = MotionCurve.kick(time, start: 1.55, duration: 0.5)
                fade = MotionCurve.loopFade(time, playback: state.playback)
            case .connected:
                settle = 1
                link = MotionCurve.progress(time, start: 0.2, duration: 0.5)
                check = MotionCurve.progress(time, start: 0.7, duration: 0.45, ease: .bouncy)
            }
        }
    }

    static func frame(state: IPhoneHeroState, time: Double) -> some View {
        let beats = Beats(state: state, time: time)
        return ZStack(alignment: .topLeading) {
            mac(glow: beats.macGlow * beats.fade)
            phone(readerPage: beats.settle * (state == .connected ? 1 : beats.fade), landing: beats.phoneLanding)
            Image(systemName: "icloud.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .heroPlaced(in: Layout.cloud)
            if state == .teaching {
                travelingCard(beats: beats)
                plane(beats: beats)
            } else {
                linkLine(progress: beats.link)
                MotionCheckmark(diameter: 20, progress: beats.check)
                    .position(Layout.checkCenter)
            }
        }
    }

    private static func mac(glow: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(HeroInk.barFill)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 3) {
                        Capsule().fill(HeroInk.textLine).frame(width: 20, height: 6)
                        Capsule().fill(HeroInk.textLine).frame(width: 20, height: 6)
                    }
                    .padding(6)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(HeroInk.outline, lineWidth: 2)
                )
                .shadow(color: HeroInk.accent.fill.opacity(0.9 * glow), radius: 6)
                .heroPlaced(in: Layout.macScreen)
            Capsule()
                .fill(HeroInk.outline)
                .heroPlaced(in: Layout.macBase)
        }
    }

    private static func phone(readerPage: Double, landing: Double) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(HeroInk.barFill)
            .overlay(readerPageContent.padding(5).padding(.top, 6).opacity(readerPage))
            .overlay(alignment: .top) {
                Capsule().fill(HeroInk.outline).frame(width: 12, height: 4).padding(.top, 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(HeroInk.outline, lineWidth: 2)
            )
            .scaleEffect(1 + 0.06 * landing, anchor: .bottom)
            .heroPlaced(in: Layout.phone)
    }

    /// A clean Reader page: mint title, calm text lines.
    private static var readerPageContent: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            Capsule().fill(HeroInk.palette.mint.ink).frame(width: 24, height: 5)
            ForEach([30.0, 27, 31, 22, 28, 18], id: \.self) { width in
                HeroTextLine(width: width, height: 3)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    /// The tab card: lifts off the Mac, arcs over iCloud, lands on the phone.
    private static func travelingCard(beats: Beats) -> some View {
        let origin = CGPoint(x: Layout.macScreen.midX, y: Layout.macScreen.midY + 2)
        let lifted = CGPoint(x: origin.x, y: origin.y - 8 * beats.lift)
        let landing = CGPoint(x: Layout.phone.midX, y: Layout.phone.midY)
        let point = MotionPath.quadBezier(lifted, control: Layout.flightControl, landing, amount: beats.flight)
        return VStack(alignment: .leading, spacing: 2) {
            Capsule().fill(HeroInk.palette.mint.ink.opacity(beats.flight)).frame(width: 14, height: 3.5)
            HeroTextLine(width: 20, height: 3)
            HeroTextLine(width: 14, height: 3)
        }
        .padding(3)
        .frame(width: Layout.cardSize.width, height: Layout.cardSize.height, alignment: .topLeading)
        .heroPanel(cornerRadius: 6)
        .scaleEffect(MotionCurve.lerp(1, 1.25, beats.settle))
        .opacity(min(beats.lift * 3, 1) * (1 - beats.settle) * beats.fade)
        .position(point)
    }

    private static func plane(beats: Beats) -> some View {
        let start = CGPoint(x: Layout.phone.minX + 4, y: Layout.phone.maxY - 16)
        let end = CGPoint(x: Layout.macScreen.maxX - 8, y: Layout.macScreen.midY)
        let control = CGPoint(x: 112, y: 92)
        let point = MotionPath.quadBezier(start, control: control, end, amount: beats.planeFlight)
        let ahead = MotionPath.quadBezier(start, control: control, end, amount: min(beats.planeFlight + 0.02, 1))
        let heading = atan2(ahead.y - point.y, ahead.x - point.x)
        let isFlying = beats.planeFlight > 0 && beats.planeFlight < 1
        // The symbol points up-right (-45°); turn it to face its heading.
        return Image(systemName: "paperplane.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HeroInk.accent.ink)
            .rotationEffect(Angle(radians: heading) + .degrees(45))
            .opacity(isFlying ? beats.fade : 0)
            .position(point)
    }

    private static func linkLine(progress: Double) -> some View {
        Path { path in
            path.move(to: Layout.linkStart)
            path.addQuadCurve(to: Layout.linkEnd, control: Layout.linkControl)
        }
        .trim(from: 0, to: progress)
        .stroke(HeroInk.palette.success.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}
