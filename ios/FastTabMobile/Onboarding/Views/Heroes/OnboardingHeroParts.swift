import SwiftUI

/// Neutral inks shared by every hero, so devices and pages read the same on
/// each screen and adapt to dark mode through `DS.Palette` and `.primary`.
enum HeroInk {
    static let deviceBody = DS.Palette.surface
    static let deviceOutline = Color.primary.opacity(0.32)
    static let textLine = Color.primary.opacity(0.18)
    static let faintFill = Color.primary.opacity(0.06)
    static let outlineWidth: CGFloat = 2
    /// Dash pattern for "not here yet" outlines.
    static let dash: [CGFloat] = [4, 3]
}

/// How a hero draws a device: normal, greyed (offline) or a dashed "missing" outline.
enum HeroDeviceLook {
    case solid
    case dimmed
    case dashed

    var opacity: Double { self == .dimmed ? 0.45 : 1 }
    var stroke: StrokeStyle {
        StrokeStyle(lineWidth: HeroInk.outlineWidth, dash: self == .dashed ? HeroInk.dash : [])
    }
}

/// A small MacBook: screen with `screen` content, plus a base. Size is the screen's.
struct HeroMac<Screen: View>: View {
    var width: Double
    var height: Double
    var look: HeroDeviceLook = .solid
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        VStack(spacing: 1.5) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(look == .dashed ? Color.clear : HeroInk.deviceBody)
                .overlay(screen().padding(3))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(HeroInk.deviceOutline, style: look.stroke)
                )
                .frame(width: width, height: height)
            Capsule()
                .strokeBorder(HeroInk.deviceOutline, style: look.stroke)
                .background(Capsule().fill(look == .dashed ? Color.clear : HeroInk.deviceOutline.opacity(0.4)))
                .frame(width: width * 1.2, height: 5)
        }
        .opacity(look.opacity)
    }
}

extension HeroMac where Screen == EmptyView {
    init(width: Double, height: Double, look: HeroDeviceLook = .solid) {
        self.init(width: width, height: height, look: look) { EmptyView() }
    }
}

/// A small iPhone outline with its Dynamic Island.
struct HeroPhone<Screen: View>: View {
    var width: Double
    var height: Double
    @ViewBuilder var screen: () -> Screen

    var body: some View {
        let corner = min(width * 0.3, 18)
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(HeroInk.deviceBody)
            .overlay(screen().clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
            .overlay(alignment: .top) {
                Capsule()
                    .fill(HeroInk.deviceOutline)
                    .frame(width: min(width * 0.32, 16), height: min(max(4, width * 0.08), 5))
                    .padding(.top, width * 0.08)
            }
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(HeroInk.deviceOutline, lineWidth: HeroInk.outlineWidth)
            )
            .frame(width: width, height: height)
    }
}

extension HeroPhone where Screen == EmptyView {
    init(width: Double, height: Double) {
        self.init(width: width, height: height) { EmptyView() }
    }
}

/// A placeholder line of text.
struct HeroTextLine: View {
    var width: Double
    var height: Double = 4
    var color: Color = HeroInk.textLine

    var body: some View {
        Capsule().fill(color).frame(width: width, height: height)
    }
}
