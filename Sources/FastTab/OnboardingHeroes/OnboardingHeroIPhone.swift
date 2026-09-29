import SwiftUI
import HeroMotion

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
        static let macScreen = CGRect(x: 8, y: 24, width: 70, height: 44)
        static let macBase = CGRect(x: 2, y: 68, width: 82, height: 5)
        static let phone = CGRect(x: 150, y: 10, width: 38, height: 78)
        static let cloud = CGRect(x: 100, y: 4, width: 26, height: 18)
        static let cardSize = CGSize(width: 26, height: 20)
        static let flightControl = CGPoint(x: 113, y: -12)
        static let linkStart = CGPoint(x: 80, y: 48)
        static let linkEnd = CGPoint(x: 148, y: 48)
        static let linkControl = CGPoint(x: 114, y: 26)
        static let checkCenter = CGPoint(x: 114, y: 37)
    }

    private struct Beats {
        var lift = 0.0
        var flight = 0.0
        var settle = 0.0
        var planeFlight = 0.0
        var macGlow = 0.0
        var link = 0.0
        var check = 0.0
        var fade = 1.0

        init(state: IPhoneHeroState, time: Double) {
            switch state {
            case .teaching:
                lift = HeroCurve.progress(time, start: 0.3, duration: 0.4, ease: .easeOut)
                flight = HeroCurve.progress(time, start: 0.7, duration: 0.9)
                settle = HeroCurve.progress(time, start: 1.6, duration: 0.4)
                planeFlight = HeroCurve.progress(time, start: 2.1, duration: 0.6)
                macGlow = HeroCurve.progress(time, start: 2.65, duration: 0.2)
                fade = HeroCurve.loopFade(time, playback: state.playback)
            case .connected:
                settle = 1
                link = HeroCurve.progress(time, start: 0.2, duration: 0.5)
                check = HeroCurve.progress(time, start: 0.7, duration: 0.3, ease: .spring)
            }
        }
    }

    static func frame(state: IPhoneHeroState, time: Double) -> some View {
        let beats = Beats(state: state, time: time)
        return ZStack(alignment: .topLeading) {
            mac(glow: beats.macGlow * beats.fade)
            phone(readerPage: beats.settle * (state == .connected ? 1 : beats.fade))
            Image(systemName: "icloud.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.secondary.opacity(0.55))
                .heroPlaced(x: Layout.cloud.minX, y: Layout.cloud.minY, width: Layout.cloud.width, height: Layout.cloud.height)
            if state == .teaching {
                travelingCard(beats: beats)
                plane(beats: beats)
            } else {
                linkLine(progress: beats.link)
                HeroSuccessCheck(diameter: 16)
                    .scaleEffect(beats.check)
                    .opacity(min(beats.check * 2, 1))
                    .position(Layout.checkCenter)
            }
        }
    }

    private static func mac(glow: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(HeroInk.barFill)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1.5).fill(HeroInk.textLine).frame(width: 18, height: 5)
                        RoundedRectangle(cornerRadius: 1.5).fill(HeroInk.textLine).frame(width: 18, height: 5)
                    }
                    .padding(5)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(HeroInk.outline, lineWidth: 1.5)
                )
                .shadow(color: Color.blue.opacity(0.8 * glow), radius: 6)
                .heroPlaced(x: Layout.macScreen.minX, y: Layout.macScreen.minY, width: Layout.macScreen.width, height: Layout.macScreen.height)
            Capsule()
                .fill(HeroInk.outline)
                .heroPlaced(x: Layout.macBase.minX, y: Layout.macBase.minY, width: Layout.macBase.width, height: Layout.macBase.height)
        }
    }

    private static func phone(readerPage: Double) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(HeroInk.barFill)
            .overlay(readerPageContent.padding(4).padding(.top, 6).opacity(readerPage))
            .overlay(alignment: .top) {
                Capsule().fill(HeroInk.outline).frame(width: 10, height: 3).padding(.top, 3)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(HeroInk.outline, lineWidth: 1.5)
            )
            .heroPlaced(x: Layout.phone.minX, y: Layout.phone.minY, width: Layout.phone.width, height: Layout.phone.height)
    }

    /// A clean Reader page: teal title, calm text lines.
    private static var readerPageContent: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            Capsule().fill(Color.teal).frame(width: 22, height: 4)
            ForEach([26.0, 24, 27, 20, 25, 16], id: \.self) { width in
                HeroTextLine(width: width, height: 2)
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
        let point = HeroPath.quadBezier(lifted, control: Layout.flightControl, landing, amount: beats.flight)
        return VStack(alignment: .leading, spacing: 2) {
            Capsule().fill(Color.teal.opacity(beats.flight)).frame(width: 12, height: 2.5)
            HeroTextLine(width: 18, height: 2)
            HeroTextLine(width: 12, height: 2)
        }
        .padding(3)
        .frame(width: Layout.cardSize.width, height: Layout.cardSize.height, alignment: .topLeading)
        .heroPanel(cornerRadius: 3)
        .scaleEffect(HeroCurve.lerp(1, 1.25, beats.settle))
        .opacity(min(beats.lift * 3, 1) * (1 - beats.settle) * beats.fade)
        .position(point)
    }

    private static func plane(beats: Beats) -> some View {
        let start = CGPoint(x: Layout.phone.minX + 4, y: Layout.phone.maxY - 16)
        let end = CGPoint(x: Layout.macScreen.maxX - 8, y: Layout.macScreen.midY)
        let control = CGPoint(x: 112, y: 92)
        let point = HeroPath.quadBezier(start, control: control, end, amount: beats.planeFlight)
        let ahead = HeroPath.quadBezier(start, control: control, end, amount: min(beats.planeFlight + 0.02, 1))
        let heading = atan2(ahead.y - point.y, ahead.x - point.x)
        let isFlying = beats.planeFlight > 0 && beats.planeFlight < 1
        // The symbol points up-right (-45°); turn it to face its heading.
        return Image(systemName: "paperplane.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.blue)
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
        .stroke(Color.green, style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}
