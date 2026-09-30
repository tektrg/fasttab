import SwiftUI
import IndieMotion

/// Step 4: the share sheet slides up on the iPhone, FastTab is tapped, and a
/// paperplane arcs to the Mac, where a new tab chip glows. Teaching loops; a
/// real successful "Try it" plays the flight once; without a Mac the Mac is
/// dashed and the plane stays parked.
struct OnboardingHeroSend: View {
    let state: SendHeroState

    private enum Layout {
        /// A real iPhone's proportions (about 9 : 19.5), standing left of the Mac.
        static let phoneOrigin = CGPoint(x: 24, y: 4)
        static let phoneSize = CGSize(width: 52, height: 112)
        static let macOrigin = CGPoint(x: 96, y: 34)
        static let macSize = CGSize(width: 66, height: 42)
        /// The share sheet covers the phone's lower half.
        static let sheetTop = 56.0
        static let chipSize = CGSize(width: 17, height: 10)
        static let chipGap = 2.0
        /// Share-sheet apps sit in a 2 × 2 grid (the phone is too narrow for a row).
        static let appIconSize = 15.0
        static let appIconGap = 5.0
        static let appGridLeft = (phoneSize.width - 2 * appIconSize - appIconGap) / 2
        static let appGridTop = 12.0
        static let flightControl = CGPoint(x: 104, y: 14)
        static let flightStart = 1.2
        static let flightDuration = 0.85
    }

    /// Share-sheet apps: FastTab is the second tile, the one tapped.
    private static let appTiles: [Color] = [HeroInk.palette.mint.fill, HeroInk.palette.blue.ink, HeroInk.palette.peach.fill, HeroInk.palette.lavender.fill]
    private static let fastTabTileIndex = 1

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state) { time in
            let fade = MotionCurve.loopFade(time, playback: state.playback)
            ZStack(alignment: .topLeading) {
                mac(time: time, fade: fade)
                    .heroPlaced(x: Layout.macOrigin.x, y: Layout.macOrigin.y, width: Layout.macSize.width * 1.2, height: Layout.macSize.height + 8)
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
        let tile = Self.appTileOrigin(Self.fastTabTileIndex)
        return CGPoint(
            x: Layout.phoneOrigin.x + tile.x + Layout.appIconSize / 2,
            y: Layout.phoneOrigin.y + Layout.sheetTop + tile.y + Layout.appIconSize / 2
        )
    }

    /// Top-left of an app tile inside the share sheet (row-major 2 × 2 grid).
    private static func appTileOrigin(_ index: Int) -> CGPoint {
        let step = Layout.appIconSize + Layout.appIconGap
        return CGPoint(x: Layout.appGridLeft + step * Double(index % 2), y: Layout.appGridTop + step * Double(index / 2))
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
                    chip(fill: HeroInk.palette.accent.ink)
                        .scaleEffect(arrival)
                        .shadow(color: HeroInk.palette.accent.fill.opacity(0.9 * arrival), radius: 4)
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
        let rise = MotionCurve.settle(time, start: 0.3, duration: 0.6)
        return HeroPhone(width: Layout.phoneSize.width, height: Layout.phoneSize.height) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    HeroTextLine(width: 30, height: 5)
                    HeroTextLine(width: 22, height: 5)
                }
                .padding(.leading, 10)
                .padding(.top, 18)

                shareSheet(time: time)
                    .offset(y: Layout.sheetTop + (1 - rise) * (Layout.phoneSize.height - Layout.sheetTop))
                    .opacity(fade)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func shareSheet(time: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Palette.surfaceMuted)
            Capsule().fill(HeroInk.deviceOutline)
                .frame(width: 18, height: 4)
                .offset(x: (Layout.phoneSize.width - 18) / 2, y: 4)
            ForEach(Self.appTiles.indices, id: \.self) { index in
                let origin = Self.appTileOrigin(index)
                appTile(index, time: time)
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .frame(width: Layout.phoneSize.width, height: Layout.phoneSize.height - Layout.sheetTop)
    }

    @ViewBuilder
    private func appTile(_ index: Int, time: Double) -> some View {
        let tile = RoundedRectangle(cornerRadius: 5, style: .continuous)
        if index == Self.fastTabTileIndex {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Layout.appIconSize, height: Layout.appIconSize)
                .background(tile.fill(Self.appTiles[index]))
                // The tap: a quick squish-and-bounce, back to exactly 1 at rest.
                .scaleEffect(1 - 0.12 * MotionCurve.kick(time, start: 0.85, duration: 0.45))
        } else {
            tile.fill(Self.appTiles[index].opacity(0.7))
                .frame(width: Layout.appIconSize, height: Layout.appIconSize)
        }
    }

    private func ripple(time: Double) -> some View {
        let spread = MotionCurve.progress(time, start: 0.9, duration: 0.4, ease: .easeOut)
        let diameter = MotionCurve.lerp(Layout.appIconSize, 40, spread)
        return Circle()
            .strokeBorder(HeroInk.palette.accent.ink, lineWidth: 2.5)
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
            let point = Self.quadBezier(fastTabIconCenter, control: Layout.flightControl, newChipCenter, amount: flight)
            let ahead = Self.quadBezier(fastTabIconCenter, control: Layout.flightControl, newChipCenter, amount: min(flight + 0.02, 1))
            let heading = atan2(ahead.y - point.y, ahead.x - point.x)
            // The symbol points up-right (-45°); turn it to face its heading.
            let rotation = isFlying ? Angle(radians: heading) + .degrees(45) : .zero
            Image(systemName: "paperplane.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(HeroInk.palette.accent.ink)
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
