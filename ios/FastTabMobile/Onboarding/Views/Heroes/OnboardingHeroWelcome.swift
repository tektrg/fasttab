import SwiftUI
import IndieMotion

/// Step 1: three tab cards flow from a small Mac into a stack on the iPhone,
/// then fan out and take the tints of the three benefit rows below
/// (purple revisit, teal reader, blue send). Loops.
struct OnboardingHeroWelcome: View {
    static let playback = MotionPlayback.loop(period: 4.0, restAt: 3.2)

    /// Same symbols and tints as the benefit rows, in the same order.
    private static let cards: [(symbol: String, tint: Color)] = [
        ("arrow.uturn.backward.circle.fill", DS.Tint.emerging),
        ("doc.plaintext.fill", DS.Tint.recent),
        ("paperplane.fill", DS.Tint.shared),
    ]
    private static let cardSize = CGSize(width: 44, height: 27)

    var body: some View {
        OnboardingHeroStage(playback: Self.playback) { time in
            ZStack(alignment: .topLeading) {
                HeroMac(width: 70, height: 44) {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in HeroTextLine(width: 14, height: 5) }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .heroPlaced(x: 0, y: 8, width: 84, height: 51)

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
        let fan = MotionCurve.progress(time, start: 1.6, duration: 0.5, ease: .spring)
        let tintAmount = MotionCurve.progress(time, start: 1.6 + 0.3 * offset, duration: 0.35)

        let scale = MotionCurve.lerp(0.6, 1, flow)
        let left = MotionCurve.lerp(12 + 6 * offset, 124, flow)
        let stackTop = 44 + 3 * offset
        let fanTop = 14 + 32 * offset
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
    let tint: Color
    let tintAmount: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .opacity(tintAmount)
            VStack(alignment: .leading, spacing: 3) {
                HeroTextLine(width: 19)
                HeroTextLine(width: 13)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .background(shape.fill(HeroInk.deviceBody))
        .overlay(shape.fill(tint.opacity(0.16 * tintAmount)))
        .overlay(shape.strokeBorder(HeroInk.deviceOutline.opacity(1 - tintAmount), lineWidth: 1))
        .overlay(shape.strokeBorder(tint.opacity(tintAmount), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
    }
}
