import SwiftUI
import IndieMotion

/// Step 4: the share sheet slides up on the iPhone, FastTab is tapped, and a
/// paperplane arcs to the Mac, where a new tab chip glows. Teaching loops; a
/// real successful "Try it" plays the flight once; without a Mac the Mac is
/// dashed and the plane stays parked.
struct OnboardingHeroSend: View {
    let state: SendHeroState

    private enum Layout {
        static let macOrigin = CGPoint(x: 53, y: 0)
        static let macSize = CGSize(width: 62, height: 38)
        static let phoneOrigin = CGPoint(x: 48, y: 46)
        static let phoneSize = CGSize(width: 84, height: 92)
        static let sheetTop = 40.0
        static let chipSize = CGSize(width: 16, height: 9)
        static let chipGap = 2.0
        static let appIconSize = 16.0
        /// Where the FastTab icon sits in the share sheet's app row (x, in phone points).
        static let fastTabIconX = 26.0
        static let appIconTop = 8.0
        static let flightStart = 1.2
        static let flightDuration = 0.85
    }

    /// Share-sheet app row: FastTab is the second tile, the one tapped.
    private static let appTiles: [Color] = [DS.Tint.success, DS.Tint.action, DS.Tint.warning, Color.secondary]
    private static let fastTabTileIndex = 1

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state) { time in
            let fade = MotionCurve.loopFade(time, playback: state.playback)
            ZStack(alignment: .topLeading) {
                mac(time: time, fade: fade)
                    .heroPlaced(x: Layout.macOrigin.x, y: Layout.macOrigin.y, width: Layout.macSize.width * 1.2, height: Layout.macSize.height + 6.5)
                phone(time: time, fade: fade)
                    .heroPlaced(x: Layout.phoneOrigin.x, y: Layout.phoneOrigin.y, width: Layout.phoneSize.width, height: Layout.phoneSize.height)
                if state != .noMac {
                    ripple(time: time).opacity(fade)
                }
                plane(time: time).opacity(fade)
            }
        }
    }

    // MARK: - Points on the canvas

    private var fastTabIconCenter: CGPoint {
        CGPoint(
            x: Layout.phoneOrigin.x + Layout.fastTabIconX + Layout.appIconSize / 2,
            y: Layout.phoneOrigin.y + Layout.sheetTop + Layout.appIconTop + Layout.appIconSize / 2
        )
    }

    /// The new tab chip, third in the Mac's tab strip.
    private var newChipCenter: CGPoint {
        let macScreenLeft = Layout.macOrigin.x + Layout.macSize.width * 0.1
        return CGPoint(
            x: macScreenLeft + 3 + 2 * (Layout.chipSize.width + Layout.chipGap) + Layout.chipSize.width / 2,
            y: Layout.macOrigin.y + 3 + Layout.chipSize.height / 2
        )
    }

    // MARK: - Parts

    private func mac(time: Double, fade: Double) -> some View {
        let arrival = MotionCurve.progress(time, start: Layout.flightStart + Layout.flightDuration, duration: 0.5, ease: .bouncy)
        return HeroMac(width: Layout.macSize.width, height: Layout.macSize.height, look: state == .noMac ? .dashed : .solid) {
            if state != .noMac {
                HStack(spacing: Layout.chipGap) {
                    chip(fill: HeroInk.textLine)
                    chip(fill: HeroInk.textLine)
                    chip(fill: DS.Tint.shared)
                        .scaleEffect(arrival)
                        .shadow(color: DS.Tint.shared.opacity(0.9 * arrival), radius: 4)
                        .opacity(fade)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func chip(fill: Color) -> some View {
        Capsule(style: .continuous)
            .fill(fill)
            .frame(width: Layout.chipSize.width, height: Layout.chipSize.height)
    }

    private func phone(time: Double, fade: Double) -> some View {
        let rise = MotionCurve.progress(time, start: 0.3, duration: 0.6, ease: .spring)
        return HeroPhone(width: Layout.phoneSize.width, height: Layout.phoneSize.height) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    HeroTextLine(width: 40)
                    HeroTextLine(width: 60)
                    HeroTextLine(width: 52)
                }
                .padding(.leading, 10)
                .padding(.top, 14)

                shareSheet
                    .offset(y: Layout.sheetTop + (1 - rise) * (Layout.phoneSize.height - Layout.sheetTop))
                    .opacity(fade)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var shareSheet: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Palette.surfaceMuted)
            Capsule().fill(HeroInk.deviceOutline)
                .frame(width: 16, height: 3)
                .offset(x: (Layout.phoneSize.width - 16) / 2, y: 3)
            ForEach(Self.appTiles.indices, id: \.self) { index in
                appTile(index)
                    .offset(x: 7 + 19 * Double(index), y: Layout.appIconTop)
            }
            VStack(alignment: .leading, spacing: 6) {
                HeroTextLine(width: 50)
                HeroTextLine(width: 40)
            }
            .offset(x: 8, y: 30)
        }
        .frame(width: Layout.phoneSize.width, height: Layout.phoneSize.height - Layout.sheetTop)
    }

    @ViewBuilder
    private func appTile(_ index: Int) -> some View {
        let tile = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if index == Self.fastTabTileIndex {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Layout.appIconSize, height: Layout.appIconSize)
                .background(tile.fill(Self.appTiles[index]))
        } else {
            tile.fill(Self.appTiles[index].opacity(0.7))
                .frame(width: Layout.appIconSize, height: Layout.appIconSize)
        }
    }

    private func ripple(time: Double) -> some View {
        let spread = MotionCurve.progress(time, start: 0.9, duration: 0.4, ease: .easeOut)
        let diameter = MotionCurve.lerp(Layout.appIconSize, 40, spread)
        return Circle()
            .strokeBorder(DS.Tint.action, lineWidth: 2)
            .frame(width: diameter, height: diameter)
            .opacity(spread > 0 && spread < 1 ? 1 - spread : 0)
            .position(fastTabIconCenter)
    }

    /// Parked on the FastTab icon, then (with a Mac) along a curve to the new chip.
    @ViewBuilder
    private func plane(time: Double) -> some View {
        let flight = state == .noMac ? 0 : MotionCurve.progress(time, start: Layout.flightStart, duration: Layout.flightDuration)
        let isParkedVisible = state == .noMac && time >= 0.8
        let isFlying = state != .noMac && time >= Layout.flightStart && flight < 1
        if isParkedVisible || isFlying {
            let point = Self.quadBezier(fastTabIconCenter, control: CGPoint(x: 160, y: 62), newChipCenter, amount: flight)
            let ahead = Self.quadBezier(fastTabIconCenter, control: CGPoint(x: 160, y: 62), newChipCenter, amount: min(flight + 0.02, 1))
            let heading = atan2(ahead.y - point.y, ahead.x - point.x)
            // The symbol points up-right (-45°); turn it to face its heading.
            let rotation = isFlying ? Angle(radians: heading) + .degrees(45) : .zero
            Image(systemName: "paperplane.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Tint.shared)
                .rotationEffect(rotation)
                .scaleEffect(isFlying ? MotionCurve.lerp(1.2, 0.8, flight) : 1)
                .position(isFlying ? point : CGPoint(x: fastTabIconCenter.x + 8, y: fastTabIconCenter.y - 8))
        }
    }

    private static func quadBezier(_ start: CGPoint, control: CGPoint, _ end: CGPoint, amount: Double) -> CGPoint {
        let inverse = 1 - amount
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * amount * control.x + amount * amount * end.x,
            y: inverse * inverse * start.y + 2 * inverse * amount * control.y + amount * amount * end.y
        )
    }
}
