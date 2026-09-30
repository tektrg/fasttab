import SwiftUI
import IndieMotion

/// Drawn-in-code art for the tab list's demo cards, on a 180 × 120 canvas scaled
/// to fill the card's art slot. House style: chibi parts, pastel, springy settles.
enum TabSearchMotionArt {
    static let canvasSize = CGSize(width: 180, height: 120)
    static let palette = MotionPalette.pastel

    static func stage<Frame: View>(in size: CGSize, playback: MotionPlayback, @ViewBuilder frame: @escaping (Double) -> Frame) -> some View {
        MotionStage(canvasSize: canvasSize, scale: size.width / canvasSize.width, playback: playback, frame: frame)
    }
}

/// A chunky magnifier: a thick ring and a capsule handle.
private struct ArtMagnifier: View {
    let tint: Color
    var body: some View {
        ZStack {
            Capsule().fill(tint).frame(width: 9, height: 22).rotationEffect(.degrees(-45)).offset(x: 17, y: 17)
            Circle().fill(Color.white.opacity(0.35))
            Circle().strokeBorder(tint, lineWidth: 7)
        }
        .frame(width: 44, height: 44)
    }
}

/// "No matches": a magnifier glides over a page of rows, finds nothing, and a
/// soft rose "?" bubble pops in. Rests on the settled "?" frame.
struct NoMatchesMotionArt: View {
    let size: CGSize
    private let playback = MotionPlayback.loop(period: 4, restAt: 3)

    var body: some View {
        TabSearchMotionArt.stage(in: size, playback: playback) { time in
            let palette = TabSearchMotionArt.palette
            let glide = MotionCurve.progress(time, start: 0.2, duration: 1.4)
            let land = MotionCurve.settle(time, start: 1.6, duration: 0.6)
            let bubble = MotionCurve.settle(time, start: 2.0, duration: 0.6)
            let fade = MotionCurve.loopFade(time, playback: playback)
            ZStack {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: 8) {
                            Circle().fill(palette.all[row + 1].fill).frame(width: 12, height: 12)
                            MotionTextLine(width: [58, 44, 52][row], height: 7, color: palette.lavender.fill)
                        }
                    }
                }
                .padding(16)
                .motionPanel(cornerRadius: 16, fill: MotionPalette.onInk, outline: palette.lavender.fill, outlineWidth: MotionStyle.boldStroke)
                .position(x: 90, y: 62)

                ArtMagnifier(tint: palette.blue.ink)
                    .scaleEffect(1 + 0.12 * (1 - land) * glide)
                    .position(x: MotionCurve.lerp(64, 112, glide), y: MotionCurve.lerp(44, 70, glide) - 6 * sin(.pi * glide))
                    .opacity(fade)

                Text(verbatim: "?")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(MotionPalette.onInk)
                    .frame(width: 30, height: 30)
                    .background(palette.rose.ink, in: Circle())
                    .scaleEffect(bubble)
                    .position(x: 146, y: 34)
                    .opacity(fade)
            }
        }
    }
}

/// "Search every Mac": a phone's search capsule sends a ping, and two Macs'
/// rows light up in turn with a springy kick. Rests with both lit.
struct SearchEveryMacMotionArt: View {
    let size: CGSize
    private let playback = MotionPlayback.loop(period: 3.6, restAt: 2.6)

    var body: some View {
        TabSearchMotionArt.stage(in: size, playback: playback) { time in
            let palette = TabSearchMotionArt.palette
            let fade = MotionCurve.loopFade(time, playback: playback)
            ZStack {
                ArtPhone(typed: MotionCurve.progress(time, start: 0.2, duration: 0.6), palette: palette)
                    .position(x: 38, y: 60)
                ForEach(0..<2, id: \.self) { index in
                    let start = 1.0 + 0.45 * Double(index)
                    ArtMac(lit: MotionCurve.settle(time, start: start, duration: 0.5) * fade, swatch: index == 0 ? palette.mint : palette.peach)
                        .scaleEffect(1 + 0.08 * MotionCurve.kick(time, start: start, duration: 0.6))
                        .position(x: 124, y: index == 0 ? 30 : 88)
                }
            }
        }
    }
}

/// iPhone at true proportions (9 : 19.5) with a search capsule filling in.
private struct ArtPhone: View {
    let typed: Double
    let palette: MotionPalette
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(MotionPalette.onInk)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.blue.ink, lineWidth: MotionStyle.boldStroke + 1))
            .overlay(alignment: .top) {
                Capsule().fill(palette.blue.fill)
                    .frame(width: 30, height: 9)
                    .overlay(alignment: .leading) {
                        Capsule().fill(palette.blue.ink).frame(width: 6 + 18 * typed, height: 4).padding(.leading, 3)
                    }
                    .padding(.top, 12)
            }
            .frame(width: 42, height: 91)
    }
}

/// A MacBook: 16 : 10 screen over a capsule base; rows fill with `lit`.
private struct ArtMac: View {
    let lit: Double
    let swatch: MotionSwatch
    var body: some View {
        VStack(spacing: 2) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<2, id: \.self) { row in
                    MotionTextLine(width: row == 0 ? 30 : 20, height: 6, color: swatch.ink.opacity(0.25 + 0.75 * lit))
                }
            }
            .frame(width: 56, height: 35)
            .background(swatch.fill.opacity(0.3 + 0.7 * lit), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(swatch.ink, lineWidth: MotionStyle.boldStroke))
            Capsule().fill(swatch.ink).frame(width: 68, height: 6)
        }
    }
}
