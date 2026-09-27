import Foundation
import OSLog
import IndieMetrics

/// Metric names and labels for tab statistics. Single source of truth for the
/// recorder (writes) and `TabStatsDigestBuilder` (reads).
enum TabMetric {
    static let opened = "tab.opened"
    static let closed = "tab.closed"
    /// Gauge: total open tabs across browsers at the sample instant.
    static let openCount = "tab.openCount"
    static let browserLabel = "browser"
    /// Subject of the `openCount` gauge: one series for the whole Mac.
    static let allBrowsersSubject = "all"
    /// Longest a gauge sample may hold. Longer gaps (Mac asleep, app quit) count
    /// as this, so asleep time barely weighs into the daily average.
    static let gaugeMaxHold: TimeInterval = 10 * 60
}

/// Turns authoritative live-tab snapshots into `tab.opened` / `tab.closed`
/// counter events and a throttled `tab.openCount` gauge, appended to a local
/// JSON-lines log (`metrics.jsonl`). Nothing about a tab but its browser is stored.
///
/// Identity is **per-browser tab count**, not per tab: tab IDs flip between the
/// extension and AppleScript schemes, and a URL-keyed diff would count every
/// in-tab navigation as a close plus an open. The cost is netting: opening one
/// tab and closing another between two snapshots records nothing.
@MainActor
final class TabActivityRecorder {
    static let shared = TabActivityRecorder(eventLog: FileMetricEventLog(fileURL: defaultLogURL))

    /// Open tabs per browser name.
    typealias TabCounts = [String: Int]

    nonisolated static let gaugeSampleInterval: TimeInterval = 5 * 60
    /// A single-snapshot change larger than this for one browser is treated as a
    /// coverage artifact (a profile appearing/disappearing from the fetch) and
    /// re-baselined without events.
    nonisolated static let maxPlausibleChangePerSnapshot = 40
    nonisolated static let retentionDays = 120
    nonisolated static let maxRetainedEvents = 200_000
    nonisolated private static let pruneInterval: TimeInterval = 24 * 60 * 60

    nonisolated static var defaultLogURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("com.trungluong.FastTab", isDirectory: true)
            .appendingPathComponent("metrics.jsonl")
    }

    let eventLog: FileMetricEventLog
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "TabActivity")
    /// `nil` until the first snapshot after launch, which is only a baseline.
    private var lastCounts: TabCounts?
    private var lastGaugeSampleAt: Date?
    private var lastPrunedAt: Date?

    init(eventLog: FileMetricEventLog) {
        self.eventLog = eventLog
    }

    /// Feed one authoritative all-browser snapshot. Appends any resulting events
    /// and then lets the sync layer decide whether to publish a fresh digest.
    func observe(_ tabs: [BrowserSearchResult], now: Date = Date()) {
        let counts = Self.tabCounts(of: tabs)
        let step = Self.recordingStep(
            previous: lastCounts,
            current: counts,
            lastGaugeSampleAt: lastGaugeSampleAt,
            now: now
        )
        lastCounts = step.nextCounts
        if step.sampledGauge { lastGaugeSampleAt = now }
        let shouldPrune = lastPrunedAt.map { now.timeIntervalSince($0) >= Self.pruneInterval } ?? true
        if shouldPrune { lastPrunedAt = now }

        let eventLog = eventLog
        let logger = logger
        let events = step.events
        Task { @MainActor in
            do {
                try await eventLog.append(events)
                if shouldPrune {
                    let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 24 * 60 * 60)
                    let dropped = try await eventLog.prune(olderThan: cutoff, maxEvents: Self.maxRetainedEvents)
                    if dropped > 0 { logger.info("Pruned \(dropped) old tab metric events") }
                }
            } catch {
                logger.error("Tab metric log write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Pure rules

    struct RecordingStep: Equatable {
        var events: [MetricEvent]
        var nextCounts: TabCounts
        var sampledGauge: Bool
    }

    /// Real tabs only: ghost slots and non-tab results are not open tabs.
    nonisolated static func tabCounts(of tabs: [BrowserSearchResult]) -> TabCounts {
        tabs.reduce(into: TabCounts()) { counts, tab in
            guard tab.type == .tab, !tab.isGhost else { return }
            counts[tab.browserName, default: 0] += 1
        }
    }

    /// Per-browser change from `previous` to `current`, and the counts to diff
    /// the next snapshot against.
    /// - A browser absent from `current` is skipped and its previous count kept
    ///   (a partial fetch, or a quit browser whose session may be restored).
    /// - A browser absent from `previous` is a baseline: first seen, no events.
    /// - A change beyond `maxPlausibleChangePerSnapshot` is re-baselined silently.
    nonisolated static func diff(previous: TabCounts, current: TabCounts) -> (changeByBrowser: [String: Int], nextCounts: TabCounts) {
        var nextCounts = previous
        var changeByBrowser: [String: Int] = [:]
        for (browser, currentCount) in current {
            nextCounts[browser] = currentCount
            guard let previousCount = previous[browser] else { continue }
            let change = currentCount - previousCount
            guard change != 0, abs(change) <= maxPlausibleChangePerSnapshot else { continue }
            changeByBrowser[browser] = change
        }
        return (changeByBrowser, nextCounts)
    }

    /// Everything one snapshot records. The first snapshot after launch
    /// (`previous == nil`) only sets the baseline and a gauge sample. The gauge
    /// is sampled at most every `gaugeSampleInterval`.
    nonisolated static func recordingStep(
        previous: TabCounts?,
        current: TabCounts,
        lastGaugeSampleAt: Date?,
        now: Date
    ) -> RecordingStep {
        var events: [MetricEvent] = []
        var nextCounts = current
        if let previous {
            let result = diff(previous: previous, current: current)
            nextCounts = result.nextCounts
            for (browser, change) in result.changeByBrowser.sorted(by: { $0.key < $1.key }) {
                let metric = change > 0 ? TabMetric.opened : TabMetric.closed
                let event = MetricEvent(
                    timestamp: now,
                    subject: browser,
                    metric: metric,
                    value: 1,
                    labels: [TabMetric.browserLabel: browser]
                )
                events.append(contentsOf: repeatElement(event, count: abs(change)))
            }
        }
        // An empty snapshot is far more often a failed fetch than a Mac with no
        // tabs, so it never samples the gauge (it would drag the average to 0).
        let gaugeIsDue = lastGaugeSampleAt.map { now.timeIntervalSince($0) >= gaugeSampleInterval } ?? true
        let sampledGauge = gaugeIsDue && !current.isEmpty
        if sampledGauge {
            events.append(MetricEvent(
                timestamp: now,
                subject: TabMetric.allBrowsersSubject,
                metric: TabMetric.openCount,
                value: Double(current.values.reduce(0, +))
            ))
        }
        return RecordingStep(events: events, nextCounts: nextCounts, sampledGauge: sampledGauge)
    }
}
