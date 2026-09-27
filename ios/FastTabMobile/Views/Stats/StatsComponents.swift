import SwiftUI

/// Pieces shared by the More tab's Reading and Tabs stat cards.
enum StatsStyle {
    /// Series colors in order: largest topic first. The last slot is always "Other".
    static let topicColors: [Color] = [DS.Tint.action, DS.Tint.emerging, DS.Tint.recent, DS.Tint.bookmark]
    static let otherTopicColor = Color.secondary.opacity(0.45)
    static let chartHeight: CGFloat = 120
    static let compactChartHeight: CGFloat = 64

    /// 12.4k, 980, 1.2M.
    static func compactNumber(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// "10 AM" in the user's locale.
    static func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    /// "Tue" for a `Calendar` weekday 1...7.
    static func weekdayLabel(_ weekday: Int) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "–"
    }
}

/// One headline number with a caption: "12.4k / words read".
struct StatTile: View {
    let value: String
    let caption: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Three headline tiles side by side; stacked at accessibility text sizes, where a third of
/// the card is too narrow for "Tue · 10 AM" or "open, 7-day avg".
struct StatTileRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DS.Space.sm) { content }
        } else {
            HStack(alignment: .top, spacing: DS.Space.md) { content }
        }
    }
}

/// Card chrome for a stats section: title row + content, on the surface.
struct StatsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let context: String?
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            // At accessibility sizes the context goes under the title, which would otherwise
            // hyphenate ("Read-ing") beside it.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DS.Space.xxs) { titleLabel; contextText }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    titleLabel
                    Spacer(minLength: DS.Space.sm)
                    contextText
                }
            }
            content
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleLabel: some View {
        Label(title, systemImage: systemImage)
            .font(DS.Font.cardTitle)
            .foregroundStyle(tint)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var contextText: some View {
        if let context {
            Text(context)
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// Axis labels stop growing at the largest non-accessibility size: past it, date labels on a
    /// phone-width chart overlap. The numbers stay readable in the headline tiles above, and
    /// VoiceOver reads every mark.
    func statsChartTextSize() -> some View {
        dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Small caption above a chart.
struct ChartCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.tag)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

/// Lays children left to right, starting a new line when the next one would not fit.
struct WrappingRowsLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = lineFrames(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = lineFrames(for: subviews, maxWidth: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func lineFrames(for subviews: Subviews, maxWidth: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var cursor = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > maxWidth {
                cursor = CGPoint(x: 0, y: cursor.y + lineHeight + lineSpacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: cursor, size: size))
            cursor.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

/// Icon + one line of guidance, for a stats card with nothing to chart yet.
struct StatsEmptyMessage: View {
    let systemImage: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: DS.IconSize.row + 4))
                .foregroundStyle(.secondary)
            Text(message)
                .font(DS.Font.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.Space.xs)
    }
}
