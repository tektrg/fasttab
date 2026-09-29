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
    var highlight: Double = 0
    var height: Double = 14

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(favicon)
                .frame(width: 7, height: 7)
            HeroTextLine(width: titleWidth)
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

/// A small command bar: search field over `rowCount` tab rows, top row selected.
struct HeroCommandBar: View {
    var rowCount: Int

    private static let titleWidths: [Double] = [46, 34, 40]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HeroSearchField()
            ForEach(0..<rowCount, id: \.self) { index in
                HeroTabRow(
                    favicon: HeroInk.favicons[index % HeroInk.favicons.count],
                    titleWidth: Self.titleWidths[index % Self.titleWidths.count],
                    highlight: index == 0 ? 1 : 0,
                    height: 12
                )
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .heroPanel()
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

/// A row of keycaps, each pressed per `press(index)`.
struct HeroKeycapRow: View {
    var keycaps: [String]
    var press: (Int) -> Double

    static let spacing: Double = 5

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(keycaps.enumerated()), id: \.offset) { index, label in
                HeroKeycap(label: label, press: press(index))
            }
        }
        .fixedSize()
    }
}

/// Green circle with a check: the "it worked" beat.
struct HeroSuccessCheck: View {
    var diameter: Double = 14

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: diameter * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Color.green, in: Circle())
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

enum HeroPath {
    static func quadBezier(_ start: CGPoint, control: CGPoint, _ end: CGPoint, amount: Double) -> CGPoint {
        let inverse = 1 - amount
        return CGPoint(
            x: inverse * inverse * start.x + 2 * inverse * amount * control.x + amount * amount * end.x,
            y: inverse * inverse * start.y + 2 * inverse * amount * control.y + amount * amount * end.y
        )
    }
}
