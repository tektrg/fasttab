import AppKit
import SwiftUI

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
    static let outlineWidth: CGFloat = 1
    /// Dash pattern for "goes here" outlines.
    static let dash: [CGFloat] = [3, 2]
    /// Tab favicons in the mini lists: blue, orange, purple, green.
    static let favicons: [Color] = [.blue, .orange, .purple, .green]
}

/// A placeholder line of text.
struct HeroTextLine: View {
    var width: Double
    var height: Double = 3
    var color: Color = HeroInk.textLine

    var body: some View {
        Capsule().fill(color).frame(width: width, height: height)
    }
}

/// One tab row: favicon square and a title line, with an accent highlight
/// for the selected row (`highlight` 1; above 1 flashes brighter).
struct HeroTabRow: View {
    var favicon: Color
    var titleWidth: Double
    var titleColor: Color = HeroInk.textLine
    var highlight: Double = 0
    var height: Double = 14

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(favicon)
                .frame(width: 7, height: 7)
            HeroTextLine(width: titleWidth, color: titleColor)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.accentColor.opacity(HeroInk.highlightOpacity * highlight))
        )
    }
}

/// The bar's search field: magnifier, typed query, optional caret.
struct HeroSearchField: View {
    var query: String = ""
    var showsCaret = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
            if !query.isEmpty {
                Text(query)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize()
            }
            if showsCaret {
                Rectangle().fill(Color.accentColor).frame(width: 1, height: 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: 14)
    }
}

/// A small command bar in the app's default look (panel background on): a
/// black panel with round corners, a warm search pill, and the tab rows on a
/// dark card. Always dark, like the real bar, whatever the system appearance.
struct HeroCommandBar: View {
    var rowCount: Int

    private static let titleWidths: [Double] = [46, 34, 40]
    private static let panelFill = Color.black
    private static let searchFill = Color(red: 0.2, green: 0.17, blue: 0.1)
    private static let cardFill = Color.white.opacity(0.07)
    private static let titleInk = Color.white.opacity(0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HeroSearchField()
                .frame(height: 13)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Self.searchFill))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { index in
                    HeroTabRow(
                        favicon: HeroInk.favicons[index % HeroInk.favicons.count],
                        titleWidth: Self.titleWidths[index % Self.titleWidths.count],
                        titleColor: Self.titleInk,
                        highlight: index == 0 ? 1 : 0,
                        height: 11
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Self.cardFill))
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Self.panelFill)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Window-like panel: bar fill, hairline outline, soft shadow.
    func heroPanel(cornerRadius: Double = 7) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(HeroInk.barFill)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(HeroInk.outline, lineWidth: HeroInk.outlineWidth)
        )
    }
}

/// A keycap; `press` 0…1 pushes it down and tints it.
struct HeroKeycap: View {
    var label: String
    var press: Double = 0

    /// Wider caps for named keys ("Space", "Return").
    static func width(for label: String) -> Double {
        label.count > 1 ? max(34, Double(label.count) * 7 + 8) : 20
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Text(label)
            .font(.system(size: label.count > 1 ? 8 : 10, weight: .semibold))
            .foregroundStyle(press > 0.5 ? Color.accentColor : .primary)
            .frame(width: Self.width(for: label), height: 20)
            .background(shape.fill(HeroInk.barFill))
            .overlay(shape.strokeBorder(HeroInk.outline, lineWidth: HeroInk.outlineWidth))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(press), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2 * (1 - press)), radius: 0, y: 1.5 * (1 - press))
            .scaleEffect(1 - 0.06 * press)
            .offset(y: 1.5 * press)
    }
}

/// A row of keycaps, each pressed per `press(index)`. Shrinks to `maxWidth`
/// when a long shortcut (four modifiers plus "Backspace") would overflow.
struct HeroKeycapRow: View {
    var keycaps: [String]
    var maxWidth: Double
    var press: (Int) -> Double

    static let spacing: Double = 5

    static func naturalWidth(of keycaps: [String]) -> Double {
        keycaps.map(HeroKeycap.width(for:)).reduce(0, +) + spacing * Double(max(keycaps.count - 1, 0))
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { index, label in
                HeroKeycap(label: label, press: press(index))
            }
        }
        .fixedSize()
        .scaleEffect(min(1, maxWidth / max(Self.naturalWidth(of: keycaps), 1)))
    }
}

/// The mouse pointer, tip at the view's top-left.
struct HeroPointer: View {
    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.primary)
            .shadow(color: Color(nsColor: .windowBackgroundColor), radius: 0.8)
            .frame(width: 12, height: 14, alignment: .topLeading)
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
