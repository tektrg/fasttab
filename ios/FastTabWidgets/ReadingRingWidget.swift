import SwiftUI
import WidgetKit

/// W3: words read today against the daily goal, Activity-ring style. Medium adds the week.
struct ReadingRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReadingRingWidget", provider: SnapshotTimelineProvider()) { entry in
            ReadingRingWidgetView(reading: entry.snapshot.reading, now: entry.date)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(WidgetDeepLink.stats.url)
        }
        .configurationDisplayName("Reading Ring")
        .description("Close your ring by reading your daily word goal.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ReadingRingWidgetView: View {
    let reading: WidgetSnapshot.Reading?
    let now: Date
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let progress = ReadingRingProgress.make(
            from: reading ?? WidgetSnapshot.Reading(dailyWordGoal: 3_000, wordsByDay: [:]),
            now: now, calendar: .current
        )
        if family == .systemMedium {
            HStack(spacing: 16) {
                todayRing(progress)
                VStack(alignment: .leading, spacing: 8) {
                    summary(progress)
                    Spacer(minLength: 0)
                    weekRow(progress.lastSevenDays)
                }
            }
        } else {
            VStack(spacing: 6) {
                todayRing(progress)
                Text("\(Int(progress.today.words).formatted()) / \(progress.today.goal.formatted())")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func todayRing(_ progress: ReadingRingProgress) -> some View {
        ReadingRingShape(fraction: progress.today.fraction, lineWidth: 14)
            .overlay {
                if progress.today.isClosed {
                    VStack(spacing: 0) {
                        Image(systemName: "checkmark").font(.title2.weight(.bold))
                        if progress.streak > 1 {
                            Text("\(progress.streak)d").font(.caption2.weight(.semibold))
                        }
                    }
                    .foregroundStyle(WidgetPalette.ring)
                } else {
                    Text("\(Int((progress.today.fraction * 100).rounded()))%")
                        .font(.headline.monospacedDigit())
                }
            }
            .padding(4)
    }

    private func summary(_ progress: ReadingRingProgress) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetHeader(title: "Reading", systemImage: "book.closed")
            Text("\(Int(progress.today.words).formatted()) words")
                .font(.title3.weight(.bold).monospacedDigit())
            Text("of \(progress.today.goal.formatted()) today")
                .font(.caption).foregroundStyle(.secondary)
            if progress.streak > 0 {
                Label("\(progress.streak)-day streak", systemImage: "flame.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WidgetPalette.accent)
            }
        }
    }

    private func weekRow(_ days: [ReadingRingDay]) -> some View {
        HStack(spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 2) {
                    ReadingRingShape(fraction: day.fraction, lineWidth: 3.5)
                        .frame(width: 20, height: 20)
                    Text(day.dayStart.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A track plus a progress arc starting at 12 o'clock.
struct ReadingRingShape: View {
    let fraction: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(WidgetPalette.ring.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(WidgetPalette.ring, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
    }
}
