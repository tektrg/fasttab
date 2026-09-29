import SwiftUI
import HeroMotion

/// Step 3: a cluttered web page (banner, ads, sidebar, cookie bar) sheds its
/// clutter, the text settles into one clean column under a teal title, and a
/// highlight sweeps one line. While the article is still preparing, the busy
/// page shimmers instead. Both loop.
struct OnboardingHeroReader: View {
    let state: ReaderHeroState
    var isSuspended = false

    @Environment(\.colorScheme) private var colorScheme

    private static let pageSize = CGSize(width: 124, height: 112)

    /// One text line's cluttered spot and clean spot, in page points.
    private struct TextLine {
        let clutteredX, clutteredY, clutteredWidth: Double
        let cleanX, cleanY, cleanWidth: Double
    }

    /// From the storyboard; the first line is the title.
    private static let lines: [TextLine] = [
        TextLine(clutteredX: 6, clutteredY: 18, clutteredWidth: 60, cleanX: 12, cleanY: 10, cleanWidth: 70),
        TextLine(clutteredX: 6, clutteredY: 24, clutteredWidth: 84, cleanX: 12, cleanY: 22, cleanWidth: 100),
        TextLine(clutteredX: 6, clutteredY: 29, clutteredWidth: 80, cleanX: 12, cleanY: 33, cleanWidth: 96),
        TextLine(clutteredX: 48, clutteredY: 42, clutteredWidth: 44, cleanX: 12, cleanY: 44, cleanWidth: 100),
        TextLine(clutteredX: 48, clutteredY: 47, clutteredWidth: 40, cleanX: 12, cleanY: 55, cleanWidth: 92),
        TextLine(clutteredX: 48, clutteredY: 52, clutteredWidth: 36, cleanX: 12, cleanY: 66, cleanWidth: 98),
        TextLine(clutteredX: 6, clutteredY: 86, clutteredWidth: 86, cleanX: 12, cleanY: 77, cleanWidth: 64),
    ]
    private static let highlightedLine = 3

    /// A piece of clutter and which way it leaves the page.
    private struct Clutter {
        let frame: CGRect
        let exit: CGSize
        let label: String?
        let color: Color
    }

    private static let clutter: [Clutter] = [
        Clutter(frame: CGRect(x: 0, y: 0, width: 124, height: 13), exit: CGSize(width: 0, height: -24), label: nil, color: DS.Tint.warning.opacity(0.35)),
        Clutter(frame: CGRect(x: 98, y: 17, width: 22, height: 66), exit: CGSize(width: 40, height: 0), label: nil, color: HeroInk.textLine),
        Clutter(frame: CGRect(x: 6, y: 36, width: 38, height: 22), exit: CGSize(width: -60, height: 0), label: "Ad", color: HeroInk.textLine),
        Clutter(frame: CGRect(x: 6, y: 62, width: 86, height: 18), exit: CGSize(width: -110, height: 0), label: "Ad", color: HeroInk.textLine),
        Clutter(frame: CGRect(x: 0, y: 98, width: 124, height: 14), exit: CGSize(width: 0, height: 24), label: nil, color: Color.primary.opacity(0.4)),
    ]

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state, isSuspended: isSuspended) { time in
            page(time: time)
                .heroPlaced(x: 28, y: 4, width: Self.pageSize.width, height: Self.pageSize.height)
        }
    }

    private func page(time: Double) -> some View {
        // Preparing holds the busy page still under the shimmer.
        let transformTime = state == .ready ? time : 0
        let fade = state == .ready ? HeroCurve.loopFade(time, playback: state.playback) : 1
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return ZStack(alignment: .topLeading) {
            Group {
                highlight(time: transformTime)
                ForEach(Self.clutter.indices, id: \.self) { index in
                    clutterPiece(index, time: transformTime)
                }
                ForEach(Self.lines.indices, id: \.self) { index in
                    textLine(index, time: transformTime)
                }
            }
            .opacity(fade)
            if state == .preparing {
                shimmer(time: time)
            }
        }
        .frame(width: Self.pageSize.width, height: Self.pageSize.height, alignment: .topLeading)
        .background(shape.fill(DS.Palette.readerPage))
        .clipShape(shape)
        .overlay(shape.strokeBorder(HeroInk.deviceOutline, lineWidth: 1))
    }

    private func clutterPiece(_ index: Int, time: Double) -> some View {
        let piece = Self.clutter[index]
        let exit = HeroCurve.progress(time, start: 0.6 + 0.05 * Double(index), duration: 0.5)
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(piece.color)
            .overlay {
                if let label = piece.label {
                    Text(label).font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .heroPlaced(x: piece.frame.minX, y: piece.frame.minY, width: piece.frame.width, height: piece.frame.height)
            .offset(x: piece.exit.width * exit, y: piece.exit.height * exit)
            .opacity(1 - exit)
    }

    private func textLine(_ index: Int, time: Double) -> some View {
        let line = Self.lines[index]
        let settle = HeroCurve.progress(time, start: 1.1, duration: 0.6)
        let isTitle = index == 0
        let height = isTitle ? HeroCurve.lerp(3, 5, settle) : 3
        let color = isTitle && settle > 0 ? DS.Tint.recent.opacity(HeroCurve.lerp(0.3, 1, settle)) : HeroInk.textLine
        return HeroTextLine(width: HeroCurve.lerp(line.clutteredWidth, line.cleanWidth, settle), height: height, color: color)
            .heroPlaced(
                x: HeroCurve.lerp(line.clutteredX, line.cleanX, settle),
                y: HeroCurve.lerp(line.clutteredY, line.cleanY, settle),
                width: HeroCurve.lerp(line.clutteredWidth, line.cleanWidth, settle),
                height: height
            )
    }

    private func highlight(time: Double) -> some View {
        let line = Self.lines[Self.highlightedLine]
        let sweep = HeroCurve.progress(time, start: 1.8, duration: 0.7, ease: .linear)
        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(DS.Tint.bookmark.opacity(0.45))
            .frame(width: (line.cleanWidth + 4) * sweep, height: 8)
            .position(x: line.cleanX - 2 + (line.cleanWidth + 4) * sweep / 2, y: line.cleanY + 1.5)
            .opacity(sweep > 0 ? 1 : 0)
    }

    private func shimmer(time: Double) -> some View {
        let travel = HeroCurve.progress(time, start: 0, duration: 1.4, ease: .linear)
        let glow = Color.white.opacity(colorScheme == .dark ? 0.16 : 0.85)
        return LinearGradient(colors: [.clear, glow, .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: 48, height: Self.pageSize.height * 1.4)
            .rotationEffect(.degrees(18))
            .position(x: HeroCurve.lerp(-30, Self.pageSize.width + 30, travel), y: Self.pageSize.height / 2)
    }
}
