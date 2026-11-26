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

/// Holds the ring numbers apart from the reader view model, so a ring change redraws only the
/// ring. Updated from the already-capped progress writes (at most every few seconds), never
/// from scroll ticks.
@MainActor
final class ReaderRingState: ObservableObject {
    @Published private(set) var model = ReaderRingModel.empty

    func update(_ next: ReaderRingModel) {
        guard next != model else { return }
        model = next
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

/// Apple-Fitness-style rings: outer = article, inner = daily goal, centre = week.
struct ReaderRingsView: View {
    @ObservedObject var state: ReaderRingState
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
