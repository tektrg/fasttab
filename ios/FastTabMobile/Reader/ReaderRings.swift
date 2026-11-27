import SwiftUI

/// What the bottom panel's rings show, as plain numbers. Pure and headless-tested
/// (`ReaderRingsTests`). Every value is clamped to 0...1 and rounded to a whole percent, so a
/// scroll tick that moves nothing visible produces an equal model and no redraw.
struct ReaderRingModel: Equatable {
    /// Outer ring: how far into this article.
    let article: Double
    /// Inner ring: today's words against the daily goal (More → Reading goal).
    let daily: Double
    /// Centre fill: this week's words against 7 × the daily goal (no separate weekly goal exists).
    let week: Double

    static let empty = ReaderRingModel(article: 0, daily: 0, week: 0)

    init(article: Double, daily: Double, week: Double) {
        self.article = Self.clamp(article)
        self.daily = Self.clamp(daily)
        self.week = Self.clamp(week)
    }

    /// Reader state → model. No goal loaded yet (or an untracked page): daily and week stay 0.
    init(articleProgress: Double, goal: ReaderDailyGoal?) {
        self.init(
            article: articleProgress,
            daily: goal?.fraction(sessionProgress: articleProgress) ?? 0,
            week: goal?.weekFraction(sessionProgress: articleProgress) ?? 0
        )
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(1, max(0, value)) * 100).rounded() / 100
    }

    private func percent(_ v: Double) -> Int { Int((v * 100).rounded()) }

    var accessibilityLabel: String {
        "Article \(percent(article))%, today \(percent(daily))%, week \(percent(week))%"
    }
}

/// The three rows of the rings popup (tap the rings in the bar). Pure, headless-tested
/// (`ReaderRingsPopupTests`). Same numbers as the rings: no new store.
struct ReaderRingsPopupModel: Equatable {
    struct Row: Equatable, Identifiable {
        enum Kind { case article, today, week }
        let kind: Kind
        let title: String
        /// "42%" for the article, "1,200 / 3,000 words" for goals, "1,200 words" when no goal.
        let detail: String
        /// 0...1, whole percent.
        let fraction: Double
        let percentText: String
        var id: String { title }
    }

    let rows: [Row]

    static let empty = ReaderRingsPopupModel(articleProgress: 0, goal: nil)

    init(articleProgress: Double, goal: ReaderDailyGoal?) {
        let article = ReaderRingModel.clamp(articleProgress)
        var rows = [Row(kind: .article, title: "Article", detail: "\(Self.percent(article))% read",
                        fraction: article, percentText: "\(Self.percent(article))%")]
        if let goal, goal.goal > 0 {
            let today = goal.words(sessionProgress: articleProgress)
            let week = goal.weekWords(sessionProgress: articleProgress)
            let todayFrac = ReaderRingModel.clamp(goal.fraction(sessionProgress: articleProgress))
            let weekFrac = ReaderRingModel.clamp(goal.weekFraction(sessionProgress: articleProgress))
            rows.append(Row(kind: .today, title: "Today",
                            detail: "\(Self.words(today)) / \(Self.words(Double(goal.goal))) words",
                            fraction: todayFrac, percentText: "\(Self.percent(todayFrac))%"))
            rows.append(Row(kind: .week, title: "This week",
                            detail: "\(Self.words(week)) / \(Self.words(Double(goal.goal * 7))) words",
                            fraction: weekFrac, percentText: "\(Self.percent(weekFrac))%"))
        } else {
            rows.append(Row(kind: .today, title: "Today", detail: "No goal loaded", fraction: 0, percentText: "–"))
            rows.append(Row(kind: .week, title: "This week", detail: "No goal loaded", fraction: 0, percentText: "–"))
        }
        self.rows = rows
    }

    private static func percent(_ v: Double) -> Int { Int((v * 100).rounded()) }

    static func words(_ v: Double) -> String {
        let n = v.isFinite ? max(0, Int(v.rounded())) : 0
        return n.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
    }

    var accessibilityLabel: String {
        rows.map { "\($0.title): \($0.detail)" + ($0.percentText == "–" ? "" : ", \($0.percentText)") }
            .joined(separator: ". ")
    }
}

/// Holds the ring numbers apart from the reader view model, so a ring change redraws only the
/// ring. Updated from the already-capped progress writes (at most every few seconds), never
/// from scroll ticks.
@MainActor
final class ReaderRingState: ObservableObject {
    @Published private(set) var model = ReaderRingModel.empty
    @Published private(set) var popup = ReaderRingsPopupModel.empty

    func update(_ next: ReaderRingModel, popup nextPopup: ReaderRingsPopupModel? = nil) {
        if next != model { model = next }
        if let nextPopup, nextPopup != popup { popup = nextPopup }
    }
}

/// Sizes of the floating bottom bar's items. The rings are the reference: every other glyph
/// is drawn at the rings' height, inside the same 44pt (HIG) tap target. Pure, headless-tested.
enum ReaderBarMetrics {
    /// Rings height; also the point size of every other bar glyph.
    static let glyphSize: CGFloat = 24
    /// Minimum tap target per item (HIG).
    static let tapTarget: CGFloat = 44
    /// Previous glyph size (`.body`, ~17pt at default Dynamic Type), kept for the test's before/after.
    static let legacyGlyphSize: CGFloat = 17

    /// Width of a bar with `items` controls and `spacing` between them (no padding).
    static func barContentWidth(items: Int, spacing: CGFloat) -> CGFloat {
        guard items > 0 else { return 0 }
        return CGFloat(items) * tapTarget + CGFloat(items - 1) * spacing
    }
}

/// Card shown when the bar's rings are tapped: a larger ring graphic + one legend row per ring.
struct ReaderRingsPopupView: View {
    @ObservedObject var state: ReaderRingState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func color(_ k: ReaderRingsPopupModel.Row.Kind) -> Color {
        switch k {
        case .article: return ReaderRingsView.articleColor
        case .today: return ReaderRingsView.dailyColor
        case .week: return ReaderRingsView.weekColor
        }
    }

    var body: some View {
        let rows = state.popup.rows
        VStack(spacing: 16) {
            ReaderRingsView(state: state, scale: 3.5)
                .frame(width: ReaderBarMetrics.glyphSize * 3.5, height: ReaderBarMetrics.glyphSize * 3.5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Circle().fill(color(row.kind)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.subheadline.weight(.semibold))
                            Text(row.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text(row.percentText).font(.headline.monospacedDigit())
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 260)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.popup.accessibilityLabel)
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// Apple-Fitness-style rings: outer = article, inner = daily goal, centre = week.
struct ReaderRingsView: View {
    @ObservedObject var state: ReaderRingState
    /// 1 in the bar; the popup draws the same rings larger.
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let articleColor = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let dailyColor = Color(red: 0.98, green: 0.27, blue: 0.37)  // Reading ring widget red
    static let weekColor = Color.green

    var body: some View {
        let m = state.model
        ZStack {
            ring(m.article, color: Self.articleColor, diameter: 22, line: 3)
            ring(m.daily, color: Self.dailyColor, diameter: 14, line: 3)
            Circle().fill(Self.weekColor.opacity(0.25)).frame(width: 5, height: 5)
            Circle().fill(Self.weekColor).frame(width: 5, height: 5)
                .scaleEffect(max(m.week, 0.001))
        }
        .frame(width: ReaderBarMetrics.glyphSize, height: ReaderBarMetrics.glyphSize)
        .scaleEffect(scale)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: m)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(m.accessibilityLabel)
    }

    private func ring(_ value: Double, color: Color, diameter: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: line)
            Circle().trim(from: 0, to: value)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}
