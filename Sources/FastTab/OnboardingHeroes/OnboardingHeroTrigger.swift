import SwiftUI
import CommandBarKit
import IndieMotion

/// Step 2: a mini screen. The pointer glides to the chosen hot spot (notch,
/// left or right edge), the trigger pill peeks out and the bar slides open
/// from it. With hovering off, the user's shortcut keys press instead.
/// Follows the step's radio choice live; loops while on screen.
struct OnboardingHeroTrigger: View {
    let state: TriggerHeroState

    var body: some View {
        OnboardingHeroStage(playback: state.playback, replayKey: state) { time in
            Self.frame(state: state, time: time)
        }
    }

    private enum Layout {
        static let screen = CGRect(x: 25, y: 4, width: 150, height: 88)
        static let menuBarHeight = 6.0
        static let notchSize = CGSize(width: 24, height: 5)
        static let pointerStart = CGPoint(x: 80, y: 58)
        static let glideStart = 0.3
        static let glideDuration = 0.8
        static let peekStart = 1.1
        static let openStart = 1.5
    }

    static func frame(state: TriggerHeroState, time: Double) -> some View {
        ZStack(alignment: .topLeading) {
            screen(state: state, time: time)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(HeroInk.outline, lineWidth: HeroInk.outlineWidth)
                )
                .heroPlaced(in: Layout.screen)
        }
    }

    /// Everything inside the screen, in screen coordinates.
    @ViewBuilder
    private static func screen(state: TriggerHeroState, time: Double) -> some View {
        ZStack(alignment: .topLeading) {
            HeroInk.faintFill
            HeroInk.faintFill.frame(height: Layout.menuBarHeight)
            switch state {
            case .keyboard(let keycaps):
                HeroShortcutPress(
                    keycaps: keycaps,
                    time: time,
                    barFrame: CGRect(x: 38, y: 10, width: 74, height: 44),
                    keysCenter: CGPoint(x: Layout.screen.width / 2, y: 71),
                    keysMaxWidth: Layout.screen.width - 8
                )
            case .hover(let style):
                hover(style: style, time: time)
            }
        }
        .frame(width: Layout.screen.width, height: Layout.screen.height, alignment: .topLeading)
    }

    private struct HotSpot {
        let pill: CGRect
        let pointerTarget: CGPoint
        let bar: CGRect
        let barAnchor: UnitPoint
        /// The screen edge the bar hangs from (notch-style corners there).
        let barEdge: Edge
        let barRows: Int
        /// The bar grows out of the pill along this axis.
        let growsVertically: Bool
    }

    private static func hotSpot(for style: EdgeRevealStyle) -> HotSpot {
        let width = Layout.screen.width
        switch style {
        case .leftEdge:
            return HotSpot(pill: CGRect(x: 0, y: 30, width: 5, height: 26), pointerTarget: CGPoint(x: 3, y: 40),
                           bar: CGRect(x: 0, y: 16, width: 72, height: 60), barAnchor: .leading, barEdge: .leading, barRows: 3, growsVertically: false)
        case .rightEdge:
            return HotSpot(pill: CGRect(x: width - 5, y: 30, width: 5, height: 26), pointerTarget: CGPoint(x: width - 6, y: 40),
                           bar: CGRect(x: width - 72, y: 16, width: 72, height: 60), barAnchor: .trailing, barEdge: .trailing, barRows: 3, growsVertically: false)
        case .notch, .off:
            return HotSpot(pill: CGRect(x: (width - 30) / 2, y: 0, width: 30, height: 9), pointerTarget: CGPoint(x: width / 2 - 1, y: 6),
                           bar: CGRect(x: 28, y: 0, width: 94, height: 50), barAnchor: .top, barEdge: .top, barRows: 2, growsVertically: true)
        }
    }

    @ViewBuilder
    private static func hover(style: EdgeRevealStyle, time: Double) -> some View {
        let spot = hotSpot(for: style)
        let playback = TriggerHeroState.hover(style).playback
        let fade = MotionCurve.loopFade(time, playback: playback)
        let glide = MotionCurve.progress(time, start: Layout.glideStart, duration: Layout.glideDuration)
        let peek = MotionCurve.progress(time, start: Layout.peekStart, duration: 0.3, ease: .spring)
        let open = MotionCurve.progress(time, start: Layout.openStart, duration: 0.4, ease: .spring)
        let pointer = CGPoint(
            x: MotionCurve.lerp(Layout.pointerStart.x, spot.pointerTarget.x, glide),
            y: MotionCurve.lerp(Layout.pointerStart.y, spot.pointerTarget.y, glide)
        )
        let barScale = MotionCurve.lerp(0.1, 1, open)

        HeroEdgePill(style: style)
            .scaleEffect(x: spot.growsVertically ? 1 : peek, y: spot.growsVertically ? peek : 1, anchor: spot.barAnchor)
            .opacity(min(peek * 2, 1) * fade)
            .heroPlaced(in: spot.pill)
        if style == .notch {
            UnevenRoundedRectangle(bottomLeadingRadius: 2.5, bottomTrailingRadius: 2.5, style: .continuous)
                .fill(Color.black)
                .heroPlaced(x: (Layout.screen.width - Layout.notchSize.width) / 2, y: 0,
                            width: Layout.notchSize.width, height: Layout.notchSize.height)
        }
        HeroCommandBar(rowCount: spot.barRows, attachedEdge: spot.barEdge)
            .scaleEffect(x: spot.growsVertically ? 1 : barScale, y: spot.growsVertically ? barScale : 1, anchor: spot.barAnchor)
            .opacity(min(open * 3, 1) * fade)
            .heroPlaced(in: spot.bar)
        HeroPointer()
            .opacity(min(MotionCurve.progress(time, start: 0, duration: 0.25) * fade, 1))
            .heroPlaced(x: pointer.x, y: pointer.y, width: 12, height: 14)
    }
}

/// The hover trigger's pill: a half-capsule flush against the screen edge it
/// hugs, the way it sits at that edge once hovering is live.
struct HeroEdgePill: View {
    let style: EdgeRevealStyle

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) / 2
            let corners = Self.corners(for: style, radius: radius)
            UnevenRoundedRectangle(
                topLeadingRadius: corners.topLeading,
                bottomLeadingRadius: corners.bottomLeading,
                bottomTrailingRadius: corners.bottomTrailing,
                topTrailingRadius: corners.topTrailing,
                style: .continuous
            )
            .fill(Color.accentColor)
        }
    }

    /// Square on the side touching the screen edge, round on the others.
    private static func corners(for style: EdgeRevealStyle, radius: CGFloat)
        -> (topLeading: CGFloat, bottomLeading: CGFloat, bottomTrailing: CGFloat, topTrailing: CGFloat) {
        switch style {
        case .off: return (radius, radius, radius, radius)
        case .notch: return (0, radius, radius, 0)
        case .leftEdge: return (0, 0, radius, radius)
        case .rightEdge: return (radius, radius, 0, 0)
        }
    }
}
