import SwiftUI
import IndieMotion

/// Step 5: teaches the Full Disk Access grant. A ghost of FastTab's icon
/// drags along an arc into the empty row of a mini System Settings list,
/// the row's toggle turns on and the lock opens (loops). Once granted: the
/// toggle flips, the lock opens and a green check bounces (plays once).
struct OnboardingHeroSafari: View {
    let state: SafariHeroState

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state) { time in
            Self.frame(state: state, time: time)
        }
    }

    private enum Layout {
        static let appIcon = CGRect(x: 6, y: 30, width: 34, height: 34)
        static let window = CGRect(x: 76, y: 4, width: 118, height: 88)
        static let rowTops: [Double] = [20, 41, 62]
        static let rowHeight = 20.0
        static let slotIconSize = 13.0
        static let dragControl = CGPoint(x: 58, y: -6)
        static let checkCenter = CGPoint(x: 58, y: 47)
    }

    /// Where the dragged icon lands: the empty (last) row's icon spot.
    private static var slotIconCenter: CGPoint {
        CGPoint(
            x: Layout.window.minX + 7 + Layout.slotIconSize / 2,
            y: Layout.window.minY + Layout.rowTops[2] + Layout.rowHeight / 2
        )
    }

    private struct Beats {
        var lift = 1.0
        var drag = 1.0
        var drop = 1.0
        var toggle = 0.0
        var unlock = 0.0
        var check = 0.0
        var fade = 1.0

        init(state: SafariHeroState, time: Double) {
            switch state {
            case .teaching:
                lift = MotionCurve.progress(time, start: 0, duration: 0.3, ease: .spring)
                drag = MotionCurve.progress(time, start: 0.3, duration: 0.9)
                drop = MotionCurve.progress(time, start: 1.3, duration: 0.45, ease: .bouncy)
                toggle = MotionCurve.progress(time, start: 1.7, duration: 0.2)
                unlock = MotionCurve.progress(time, start: 2.1, duration: 0.2)
                fade = MotionCurve.loopFade(time, playback: state.playback)
            case .granted:
                toggle = MotionCurve.progress(time, start: 0.25, duration: 0.2)
                unlock = MotionCurve.progress(time, start: 0.55, duration: 0.2)
                check = MotionCurve.progress(time, start: 0.85, duration: 0.3, ease: .spring)
            }
        }
    }

    static func frame(state: SafariHeroState, time: Double) -> some View {
        let beats = Beats(state: state, time: time)
        return ZStack(alignment: .topLeading) {
            HeroAppIcon(size: Layout.appIcon.width)
                .heroPlaced(in: Layout.appIcon)
            settingsWindow(beats: beats)
                .heroPlaced(in: Layout.window)
            if state == .teaching {
                ghost(beats: beats)
            }
            MotionCheckmark(diameter: 18, progress: beats.check)
                .position(Layout.checkCenter)
        }
    }

    /// The translucent copy of the icon being dragged, pointer attached.
    private static func ghost(beats: Beats) -> some View {
        let start = CGPoint(x: Layout.appIcon.midX, y: Layout.appIcon.midY)
        let point = MotionPath.quadBezier(start, control: Layout.dragControl, slotIconCenter, amount: beats.drag)
        let size = MotionCurve.lerp(Layout.appIcon.width, Layout.slotIconSize + 3, beats.drag)
        return HeroAppIcon(size: size)
            .overlay(alignment: .bottomTrailing) { HeroPointer().offset(x: 7, y: 9) }
            .scaleEffect(MotionCurve.lerp(1, 1.08, beats.lift))
            .opacity(0.75 * min(beats.lift, 1) * max(1 - beats.drop * 3, 0) * beats.fade)
            .position(point)
    }

    private static func settingsWindow(beats: Beats) -> some View {
        VStack(spacing: 0) {
            titleBar(unlock: beats.unlock)
            ForEach(Layout.rowTops.indices, id: \.self) { index in
                row(index: index, beats: beats)
            }
            Spacer(minLength: 0)
        }
        .frame(width: Layout.window.width, height: Layout.window.height)
        .heroPanel()
    }

    private static func titleBar(unlock: Double) -> some View {
        HStack(spacing: 2.5) {
            ForEach([HeroInk.palette.rose.fill, HeroInk.palette.butter.fill, HeroInk.palette.mint.fill], id: \.self) { light in
                Circle().fill(light).frame(width: 5, height: 5)
            }
            Text("Full Disk Access")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
            Spacer(minLength: 0)
            Image(systemName: unlock > 0.5 ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(unlock > 0.5 ? HeroInk.palette.success.ink : Color.secondary)
                .scaleEffect(1 + 0.25 * sin(unlock * .pi))
        }
        .padding(.horizontal, 6)
        .frame(height: Layout.rowTops[0])
    }

    /// Two apps already listed, then FastTab's row: empty until dropped in.
    @ViewBuilder
    private static func row(index: Int, beats: Beats) -> some View {
        let isFastTabRow = index == Layout.rowTops.count - 1
        HStack(spacing: 5) {
            if isFastTabRow {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(HeroInk.outline, style: StrokeStyle(lineWidth: 1, dash: HeroInk.dash))
                        .opacity(max(1 - beats.drop, 0))
                    HeroAppIcon(size: Layout.slotIconSize)
                        .scaleEffect(MotionCurve.lerp(0.6, 1, beats.drop))
                        .opacity(min(beats.drop * 3, 1))
                }
                .frame(width: Layout.slotIconSize, height: Layout.slotIconSize)
                HeroTextLine(width: 36).opacity(min(beats.drop, 1))
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(index == 0 ? HeroInk.palette.lavender.fill : HeroInk.palette.blue.fill)
                    .frame(width: Layout.slotIconSize, height: Layout.slotIconSize)
                HeroTextLine(width: index == 0 ? 40 : 32)
            }
            Spacer(minLength: 0)
            HeroToggle(isOn: isFastTabRow ? beats.toggle : (index == 0 ? 1 : 0))
        }
        .padding(.horizontal, 7)
        .frame(height: Layout.rowHeight)
        .background(isFastTabRow ? HeroInk.accent.fill.opacity(0.3 * min(beats.drop, 1)) : .clear)
    }
}

/// A mini switch; `isOn` 0…1 slides the knob and fills it with the success pastel.
struct HeroToggle: View {
    var isOn: Double

    var body: some View {
        Capsule()
            .fill(HeroInk.faintFill)
            .overlay(Capsule().fill(HeroInk.palette.success.fill.opacity(isOn)))
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0.5)
                    .frame(width: 8, height: 8)
                    .padding(1)
                    .offset(x: 8 * isOn)
            }
            .frame(width: 18, height: 10)
    }
}
