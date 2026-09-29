import SwiftUI
import HeroMotion

/// Step 4: without the extension, Recents is a guess. While not usable the
/// puzzle piece bobs beside its socket (loops); once usable it snaps in, a
/// green check bounces, the rows fall into true order and the playing tab
/// rises to the top (plays once).
struct OnboardingHeroExtension: View {
    let state: ExtensionHeroState

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state) { time in
            Self.frame(state: state, time: time)
        }
    }

    private enum Layout {
        static let list = CGRect(x: 30, y: 6, width: 124, height: 84)
        static let rowTop = 20.0
        static let rowPitch = 15.0
        static let socket = CGRect(x: 154, y: 32, width: 9, height: 18)
        static let pieceSize = 20.0
        static let pieceParkedX = 170.0
        static let pieceSnappedX = 151.0
        static let pieceY = 31.0
        static let checkCenter = CGPoint(x: 169, y: 65)
    }

    /// One Recents row and where it sits: guessed, true order, then with
    /// the playing tab risen to the top.
    private struct RecentRow {
        let favicon: Color
        let titleWidth: Double
        let guessedSlot: Int
        let trueSlot: Int
        let playingFirstSlot: Int
        var isPlaying = false
    }

    private static let rows = [
        RecentRow(favicon: HeroInk.favicons[0], titleWidth: 56, guessedSlot: 2, trueSlot: 0, playingFirstSlot: 1),
        RecentRow(favicon: HeroInk.favicons[1], titleWidth: 44, guessedSlot: 0, trueSlot: 1, playingFirstSlot: 2),
        RecentRow(favicon: HeroInk.favicons[2], titleWidth: 50, guessedSlot: 3, trueSlot: 2, playingFirstSlot: 0, isPlaying: true),
        RecentRow(favicon: HeroInk.favicons[3], titleWidth: 38, guessedSlot: 1, trueSlot: 3, playingFirstSlot: 3),
    ]

    /// Beat progress for each part of the picture.
    private struct Beats {
        var snap = 0.0
        var check = 0.0
        var reorder = 0.0
        var rise = 0.0
        var bobOffset = 0.0
        var pieceArrival = 1.0
        var fade = 1.0

        init(state: ExtensionHeroState, time: Double) {
            switch state {
            case .teaching:
                pieceArrival = HeroCurve.progress(time, start: 0, duration: 0.5, ease: .easeOut)
                let bobPhase = max(time - 0.5, 0) / 1.3 * 2 * .pi
                bobOffset = -sin(bobPhase) * 2.5
                fade = HeroCurve.loopFade(time, playback: state.playback)
            case .connected:
                snap = HeroCurve.progress(time, start: 0, duration: 0.25, ease: .spring)
                check = HeroCurve.progress(time, start: 0.25, duration: 0.25, ease: .spring)
                reorder = HeroCurve.progress(time, start: 0.4, duration: 0.4)
                rise = HeroCurve.progress(time, start: 0.8, duration: 0.3, ease: .spring)
            }
        }
    }

    static func frame(state: ExtensionHeroState, time: Double) -> some View {
        let beats = Beats(state: state, time: time)
        return ZStack(alignment: .topLeading) {
            list(beats: beats)
                .heroPlaced(x: Layout.list.minX, y: Layout.list.minY, width: Layout.list.width, height: Layout.list.height)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(HeroInk.outline, style: StrokeStyle(lineWidth: 1, dash: HeroInk.dash))
                .heroPlaced(x: Layout.socket.minX, y: Layout.socket.minY, width: Layout.socket.width, height: Layout.socket.height)
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .offset(x: (1 - beats.pieceArrival) * 16, y: beats.bobOffset)
                .opacity(beats.pieceArrival * beats.fade)
                .heroPlaced(
                    x: HeroCurve.lerp(Layout.pieceParkedX, Layout.pieceSnappedX, beats.snap),
                    y: Layout.pieceY,
                    width: Layout.pieceSize,
                    height: Layout.pieceSize
                )
            HeroSuccessCheck()
                .scaleEffect(beats.check)
                .opacity(min(beats.check * 2, 1))
                .position(Layout.checkCenter)
        }
    }

    private static func list(beats: Beats) -> some View {
        ZStack(alignment: .topLeading) {
            header(isLive: beats.reorder > 0.5)
                .padding(.horizontal, 5)
                .frame(height: 16)
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                let slot = HeroCurve.lerp(
                    HeroCurve.lerp(Double(row.guessedSlot), Double(row.trueSlot), beats.reorder),
                    Double(row.playingFirstSlot),
                    beats.rise
                )
                HeroTabRow(favicon: row.favicon, titleWidth: row.titleWidth, highlight: row.isPlaying ? beats.rise : 0)
                    .overlay(alignment: .trailing) {
                        if row.isPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(Color.accentColor)
                                .padding(.trailing, 6)
                        }
                    }
                    .padding(.horizontal, 3)
                    .offset(y: Layout.rowTop + slot * Layout.rowPitch)
            }
        }
        .frame(width: Layout.list.width, height: Layout.list.height, alignment: .topLeading)
        .heroPanel()
    }

    private static func header(isLive: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "clock")
                .font(.system(size: 7, weight: .semibold))
            Text("Recents")
                .font(.system(size: 7, weight: .semibold))
            Spacer(minLength: 0)
            Text(isLive ? "live order" : "guessing")
                .font(.system(size: 6, weight: .semibold))
                .foregroundStyle(isLive ? Color.green : Color.orange)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill((isLive ? Color.green : Color.orange).opacity(0.15)))
        }
        .foregroundStyle(.secondary)
    }
}
