import SwiftUI
import IndieMotion

/// Step 1: three tab cards flow from a small Mac into a stack on the iPhone,
/// then fan out and take the tints of the three benefit rows below
/// (lavender revisit, mint reader, blue send; pastel hues of the rows' tints). Loops.
struct OnboardingHeroWelcome: View {
    static let playback = MotionPlayback.loop(period: 4.0, restAt: 3.2)

    /// Same symbols and tints as the benefit rows, in the same order.
    private static let cards: [(symbol: String, tint: MotionSwatch)] = [
        ("arrow.uturn.backward.circle.fill", HeroInk.palette.lavender),
        ("doc.plaintext.fill", HeroInk.palette.mint),
        ("paperplane.fill", HeroInk.palette.blue),
    ]
    private static let cardSize = CGSize(width: 48, height: 33)
    /// Fanned-out tops: the first card, then one card height plus a relaxed gap.
    private static let fanFirstTop = 7.0
    private static let fanPitch = 37.0

    var body: some View {
        OnboardingHeroStage(playback: Self.playback) { time in
            ZStack(alignment: .topLeading) {
                HeroMac(width: 76, height: 48) {
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { _ in HeroTextLine(width: 15, height: 6) }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .heroPlaced(x: 0, y: 6, width: 91.2, height: 56)

                HeroPhone(width: 52, height: 112)
                    .heroPlaced(x: 120, y: 4, width: 52, height: 112)

                ForEach(Self.cards.indices, id: \.self) { index in
                    card(index, time: time)
                }
            }
        }
    }

    private func card(_ index: Int, time: Double) -> some View {
        let offset = Double(index)
        let flow = MotionCurve.progress(time, start: 0.3 + 0.12 * offset, duration: 0.7)
        let fan = MotionCurve.settle(time, start: 1.6, duration: 0.6)
        // Each card lands with its own little bounce, staggered like the tints.
        let landing = MotionCurve.kick(time, start: 1.6 + 0.12 * offset, duration: 0.6)
        let tintAmount = MotionCurve.progress(time, start: 1.6 + 0.3 * offset, duration: 0.35)

        let scale = MotionCurve.lerp(0.6, 1, flow) * (1 + 0.08 * landing)
        let left = MotionCurve.lerp(12 + 6 * offset, 122, flow)
        let stackTop = 44 + 3 * offset
        let fanTop = Self.fanFirstTop + Self.fanPitch * offset
        // A gentle arc on the way over, like the card is carried.
        let lift = sin(.pi * flow) * 14
        let top = MotionCurve.lerp(MotionCurve.lerp(12 + 5 * offset, stackTop, flow), fanTop, fan) - lift

        let spec = Self.cards[index]
        return HeroTabCard(symbol: spec.symbol, tint: spec.tint, tintAmount: tintAmount)
            .frame(width: Self.cardSize.width, height: Self.cardSize.height)
            .scaleEffect(scale, anchor: .topLeading)
            .position(x: left + Self.cardSize.width / 2, y: top + Self.cardSize.height / 2)
            .opacity(MotionCurve.loopFade(time, playback: Self.playback))
    }
}

/// A browser tab as a small card; `tintAmount` 0…1 fades in its benefit color.
struct HeroTabCard: View {
    let symbol: String
    let tint: MotionSwatch
    let tintAmount: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint.ink)
                .opacity(tintAmount)
            VStack(alignment: .leading, spacing: 4) {
                HeroTextLine(width: 19, height: 5)
                HeroTextLine(width: 13, height: 5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(shape.fill(HeroInk.deviceBody))
        .overlay(shape.fill(tint.fill.opacity(0.45 * tintAmount)))
        .overlay(shape.strokeBorder(HeroInk.deviceOutline.opacity(1 - tintAmount), lineWidth: 1.5))
        .overlay(shape.strokeBorder(tint.ink.opacity(0.75 * tintAmount), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}
