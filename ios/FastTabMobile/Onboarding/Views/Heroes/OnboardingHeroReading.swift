import IndieMotion
import SwiftUI

/// Reader-first welcome: a link drops into the phone, opens as an article,
/// a line gets highlighted and the page is bookmarked. Phone only, no Mac.
struct OnboardingHeroReading: View {
    static let playback = MotionPlayback.loop(period: 4.4, restAt: 3.4)

    private static let phone = CGRect(x: 64, y: 4, width: 52, height: 112)
    /// Article line widths, top to bottom; the highlighted one is `highlightLine`.
    private static let lines: [Double] = [30, 36, 34, 36, 26, 34, 30]
    private static let highlightLine = 3

    var body: some View {
        OnboardingHeroStage(playback: Self.playback) { time in
            ZStack(alignment: .topLeading) {
                HeroPhone(width: Self.phone.width, height: Self.phone.height) {
                    article(time: time)
                }
                .heroPlaced(x: Self.phone.minX, y: Self.phone.minY, width: Self.phone.width, height: Self.phone.height)

                linkCard(time: time)
                bookmark(time: time)
            }
            .opacity(MotionCurve.loopFade(time, playback: Self.playback))
        }
    }

    /// The saved link flies in from the left with a little arc and shrinks into the phone.
    private func linkCard(time: Double) -> some View {
        let flow = MotionCurve.progress(time, start: 0.2, duration: 0.7)
        let size = CGSize(width: 48, height: 33)
        let left = MotionCurve.lerp(4, Self.phone.midX - size.width / 2, flow)
        let top = MotionCurve.lerp(40, 48, flow) - sin(.pi * flow) * 16
        return HeroTabCard(symbol: "link", tint: HeroInk.palette.peach, tintAmount: 1)
            .frame(width: size.width, height: size.height)
            .scaleEffect(MotionCurve.lerp(1, 0.5, flow))
            .position(x: left + size.width / 2, y: top + size.height / 2)
            .opacity(1 - MotionCurve.progress(time, start: 0.8, duration: 0.2))
    }

    /// Text lines fade in once the link lands; one gets a butter highlight swept across it.
    private func article(time: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HeroTextLine(width: 24, height: 7)
                .opacity(MotionCurve.progress(time, start: 0.9, duration: 0.25))
                .padding(.bottom, 3)
            ForEach(Self.lines.indices, id: \.self) { index in
                let appear = MotionCurve.progress(time, start: 1.0 + 0.06 * Double(index), duration: 0.25)
                HeroTextLine(width: Self.lines[index], height: 4)
                    .background(alignment: .leading) {
                        if index == Self.highlightLine {
                            let sweep = MotionCurve.settle(time, start: 1.8, duration: 0.5)
                            Capsule()
                                .fill(HeroInk.palette.butter.fill)
                                .frame(width: (Self.lines[index] + 4) * sweep, height: 8)
                                .offset(x: -2)
                        }
                    }
                    .opacity(appear)
            }
        }
        .padding(.top, 20)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A bookmark ribbon drops onto the phone's top-right corner with a small bounce.
    private func bookmark(time: Double) -> some View {
        let drop = MotionCurve.settle(time, start: 2.5, duration: 0.45)
        let bounce = MotionCurve.kick(time, start: 2.5, duration: 0.6)
        return Image(systemName: "bookmark.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(HeroInk.palette.lavender.ink)
            .scaleEffect(1 + 0.15 * bounce)
            .position(x: Self.phone.maxX - 12, y: MotionCurve.lerp(-6, Self.phone.minY + 12, drop))
            .opacity(drop > 0 ? 1 : 0)
    }
}
