import AppKit
import SwiftUI
import IndieMotion

/// Neutral inks shared by every Mac hero, from semantic system colors so
/// they read the same in light and dark mode.
enum HeroInk {
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let barFill = Color(nsColor: .controlBackgroundColor)
    static let outline = Color.primary.opacity(0.22)
    static let textLine = Color.primary.opacity(0.2)
    static let faintFill = Color.primary.opacity(0.06)
    /// Accent opacity of a selected row at `highlight` 1.
    static let highlightOpacity = 0.22
    static let outlineWidth = MotionStyle.fineStroke
    /// Dash pattern for "goes here" outlines.
    static let dash: [CGFloat] = [3, 2]
    /// Chibi corner radii: soft and round everywhere.
    static let cardRadius = MotionStyle.cardRadius
    static let panelRadius = MotionStyle.panelRadius
    /// Tab favicons in the mini lists: blue, orange, purple, green.
    static let favicons: [Color] = [.blue, .orange, .purple, .green]
}

/// A placeholder line of text in the hero ink (IndieMotion's `MotionTextLine`).
struct HeroTextLine: View {
    var width: Double
    var height: Double = 4
    var color: Color = HeroInk.textLine

    var body: some View {
        MotionTextLine(width: width, height: height, color: color)
    }
}

/// One tab row: favicon square and a title line, with an accent highlight
/// for the selected row (`highlight` 1; above 1 flashes brighter).
struct HeroTabRow: View {
    var favicon: Color
    var titleWidth: Double
    var titleColor: Color = HeroInk.textLine
    var highlight: Double = 0
    var height: Double = 16

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(favicon)
                .frame(width: 9, height: 9)
            HeroTextLine(width: titleWidth, color: titleColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: height)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(HeroInk.highlightOpacity * highlight))
        )
    }
}

/// The bar's search field: magnifier, typed query, optional caret.
struct HeroSearchField: View {
    var query: String = ""
    var showsCaret = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            if !query.isEmpty {
                Text(query)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
            if showsCaret {
                Capsule().fill(Color.accentColor).frame(width: 2, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
    }
}

/// A small command bar in the app's default look (panel background on): a
/// black panel with round corners, a warm search pill, and the tab rows on a
/// dark card. Always dark, like the real bar, whatever the system appearance.
struct HeroCommandBar: View {
    var rowCount: Int
    /// The screen edge the bar hangs from, if any: its two corners there flare
    /// outward into the edge ("notch style"), like the real bar.
    var attachedEdge: Edge? = nil

    private static let titleWidths: [Double] = [44, 32, 38]
    private static let panelFill = Color.black
    private static let searchFill = Color(red: 0.2, green: 0.17, blue: 0.1)
    private static let cardFill = Color.white.opacity(0.07)
    private static let titleInk = Color.white.opacity(0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HeroSearchField()
                .frame(height: 17)
                .background(Capsule(style: .continuous).fill(Self.searchFill))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { index in
                    HeroTabRow(
                        favicon: HeroInk.favicons[index % HeroInk.favicons.count],
                        titleWidth: Self.titleWidths[index % Self.titleWidths.count],
                        titleColor: Self.titleInk,
                        highlight: index == 0 ? 1 : 0,
                        height: 12
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: HeroInk.cardRadius, style: .continuous).fill(Self.cardFill))
        }
        .padding(4)
        .background(
            MotionEdgePanelShape(attachedEdge: attachedEdge)
                .fill(Self.panelFill)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Window-like panel in the hero inks (IndieMotion's `motionPanel`).
    func heroPanel(cornerRadius: Double = HeroInk.panelRadius) -> some View {
        motionPanel(cornerRadius: cornerRadius, fill: HeroInk.barFill, outline: HeroInk.outline)
    }
}

/// A row of keycaps in the hero inks (IndieMotion's `MotionKeycapRow`).
struct HeroKeycapRow: View {
    var keycaps: [String]
    var maxWidth: Double
    var press: (Int) -> Double

    var body: some View {
        MotionKeycapRow(keycaps: keycaps, maxWidth: maxWidth, fill: HeroInk.barFill, outline: HeroInk.outline, press: press)
    }
}

/// The mouse pointer with a window-coloured halo (IndieMotion's `MotionPointer`).
struct HeroPointer: View {
    static let size = MotionPointer.size

    var body: some View {
        MotionPointer(halo: HeroInk.surface)
    }
}

/// FastTab's own app icon.
struct HeroAppIcon: View {
    var size: Double

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
