import Testing
import Foundation
import IndieMetrics
@testable import FastTab
@testable import FastTabSync

@Suite("Tab activity recorder rules")
struct TabActivityRecorderTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func tab(_ browser: String, _ url: String, tabID: Int? = nil, window: Int? = 1, index: Int? = nil) -> BrowserSearchResult {
        BrowserSearchResult(title: url, url: url, browserName: browser, type: .tab, timestamp: start,
                            windowIndex: window, tabIndex: index, tabID: tabID)
    }

    private func metrics(_ events: [MetricEvent], _ metric: String) -> [MetricEvent] {
        events.filter { $0.metric == metric }
    }

    @Test("First snapshot after launch is a baseline: no opened/closed, one gauge sample")
    func firstSnapshotIsBaseline() {
        let step = TabActivityRecorder.recordingStep(previous: nil, current: ["Chrome": 12], lastGaugeSampleAt: nil, now: start)
        #expect(metrics(step.events, TabMetric.opened).isEmpty)
        #expect(metrics(step.events, TabMetric.closed).isEmpty)
        #expect(metrics(step.events, TabMetric.openCount).map(\.value) == [12])
        #expect(step.nextCounts == ["Chrome": 12])
        #expect(step.sampledGauge)
    }

    @Test("Opened and closed tabs emit one value-1 event each, labelled by browser")
    func openAndClose() {
        let step = TabActivityRecorder.recordingStep(
            previous: ["Chrome": 5, "Safari": 3],
            current: ["Chrome": 7, "Safari": 2],
            lastGaugeSampleAt: start, now: start.addingTimeInterval(10)
        )
        let opened = metrics(step.events, TabMetric.opened)
        let closed = metrics(step.events, TabMetric.closed)
        #expect(opened.count == 2)
        #expect(opened.allSatisfy { $0.value == 1 && $0.labels[TabMetric.browserLabel] == "Chrome" })
        #expect(closed.count == 1)
        #expect(closed.first?.labels[TabMetric.browserLabel] == "Safari")
        #expect(metrics(step.events, TabMetric.openCount).isEmpty, "gauge throttled to 5 min")
    }

    @Test("A browser missing from a snapshot is skipped and keeps its count")
    func missingBrowserSkipped() {
        let result = TabActivityRecorder.diff(previous: ["Chrome": 5, "Safari": 3], current: ["Chrome": 5])
        #expect(result.changeByBrowser.isEmpty)
        #expect(result.nextCounts == ["Chrome": 5, "Safari": 3])
        // When it comes back unchanged (session restored), still nothing.
        let back = TabActivityRecorder.diff(previous: result.nextCounts, current: ["Chrome": 5, "Safari": 3])
        #expect(back.changeByBrowser.isEmpty)
    }

    @Test("A browser first seen mid-session is a baseline, not a burst of opens")
    func newBrowserIsBaseline() {
        let result = TabActivityRecorder.diff(previous: ["Chrome": 5], current: ["Chrome": 5, "Arc": 30])
        #expect(result.changeByBrowser.isEmpty)
        #expect(result.nextCounts["Arc"] == 30)
    }

    @Test("Tab-ID scheme flip (extension <-> AppleScript) and navigation emit nothing")
    func schemeFlipNoEvents() {
        let extensionSnapshot = [tab("Chrome", "https://a.com", tabID: 101), tab("Chrome", "https://b.com", tabID: 102)]
        let appleScriptSnapshot = [tab("Chrome", "https://a.com", index: 1), tab("Chrome", "https://c.com", index: 2)]
        let step = TabActivityRecorder.recordingStep(
            previous: TabActivityRecorder.tabCounts(of: extensionSnapshot),
            current: TabActivityRecorder.tabCounts(of: appleScriptSnapshot),
            lastGaugeSampleAt: start, now: start.addingTimeInterval(5)
        )
        #expect(step.events.isEmpty)
    }

    @Test("Duplicate URLs count as separate tabs; ghosts and non-tabs are ignored")
    func duplicateURLs() {
        let ghost = BrowserSearchResult(title: "g", url: "https://a.com", browserName: "Chrome", type: .tab, timestamp: start, isGhost: true)
        let bookmark = BrowserSearchResult(title: "b", url: "https://a.com", browserName: "Chrome", type: .bookmark, timestamp: start)
        let counts = TabActivityRecorder.tabCounts(of: [tab("Chrome", "https://a.com"), tab("Chrome", "https://a.com"), ghost, bookmark])
        #expect(counts == ["Chrome": 2])
        let closedOneDuplicate = TabActivityRecorder.diff(previous: counts, current: ["Chrome": 1])
        #expect(closedOneDuplicate.changeByBrowser == ["Chrome": -1])
    }

    @Test("An implausible burst is re-baselined without events")
    func burstBackstop() {
        let limit = TabActivityRecorder.maxPlausibleChangePerSnapshot
        let result = TabActivityRecorder.diff(previous: ["Chrome": 80], current: ["Chrome": 80 - limit - 1])
        #expect(result.changeByBrowser.isEmpty)
        #expect(result.nextCounts["Chrome"] == 80 - limit - 1)
        let atLimit = TabActivityRecorder.diff(previous: ["Chrome": 80], current: ["Chrome": 80 - limit])
        #expect(atLimit.changeByBrowser == ["Chrome": -limit])
    }

    @Test("Gauge samples at most every 5 minutes, and never from an empty snapshot")
    func gaugeThrottle() {
        let due = start.addingTimeInterval(TabActivityRecorder.gaugeSampleInterval)
        let early = TabActivityRecorder.recordingStep(previous: ["Chrome": 1], current: ["Chrome": 1], lastGaugeSampleAt: start, now: due.addingTimeInterval(-1))
        #expect(!early.sampledGauge)
        let onTime = TabActivityRecorder.recordingStep(previous: ["Chrome": 1], current: ["Chrome": 1], lastGaugeSampleAt: start, now: due)
        #expect(onTime.sampledGauge)
        let empty = TabActivityRecorder.recordingStep(previous: ["Chrome": 1], current: [:], lastGaugeSampleAt: nil, now: due)
        #expect(!empty.sampledGauge)
        #expect(empty.events.isEmpty)
    }

    @Test("A live snapshot counts only with one connection and an extension-served authoritative fetch")
    func liveSnapshotCompleteness() {
        let extensionServed = [tab("Chrome", "https://a.com", tabID: 1), tab("Chrome", "https://b.com", tabID: 2)]
        let appleScriptServed = [tab("Chrome", "https://a.com", index: 1)]
        #expect(TabActivityRecorder.isLiveSnapshotComplete(browser: "Chrome", authoritativeTabs: extensionServed, connectionCount: 1))
        #expect(!TabActivityRecorder.isLiveSnapshotComplete(browser: "Chrome", authoritativeTabs: extensionServed, connectionCount: 2), "multi-profile: one connection is one profile")
        #expect(!TabActivityRecorder.isLiveSnapshotComplete(browser: "Chrome", authoritativeTabs: appleScriptServed, connectionCount: 1), "extension not covering every profile")
        #expect(!TabActivityRecorder.isLiveSnapshotComplete(browser: "Chrome", authoritativeTabs: [], connectionCount: 1))
    }

    @Test("Live then stale authoritative then repeats: each real open counted exactly once")
    func liveAndAuthoritativeInterleave() {
        let fetchStarted = start
        let liveAt = start.addingTimeInterval(1)
        // Live snapshot: Chrome 5 -> 6 (one real open), partial (Chrome only).
        let live = TabActivityRecorder.recordingStep(
            previous: ["Chrome": 5, "Safari": 3], current: ["Chrome": 6],
            gaugeBrowsers: ["Chrome", "Safari"], lastGaugeSampleAt: nil, now: liveAt
        )
        #expect(live.events.filter { $0.metric == TabMetric.opened }.count == 1)
        #expect(live.events.first { $0.metric == TabMetric.openCount }?.value == 9, "gauge totals the whole Mac")
        // An authoritative fetch that started before the live snapshot still says 5.
        let staleCounts = TabActivityRecorder.droppingBrowsersObservedLive(
            after: fetchStarted, from: ["Chrome": 5, "Safari": 3], lastLiveObservedAt: ["Chrome": liveAt]
        )
        #expect(staleCounts == ["Safari": 3])
        let stale = TabActivityRecorder.recordingStep(previous: live.nextCounts, current: staleCounts, lastGaugeSampleAt: liveAt, now: liveAt.addingTimeInterval(1))
        #expect(stale.events.isEmpty, "no phantom close/re-open")
        // The same live snapshot repeated (window focus), and a fresh authoritative one agreeing.
        let repeated = TabActivityRecorder.recordingStep(previous: stale.nextCounts, current: ["Chrome": 6], lastGaugeSampleAt: liveAt, now: liveAt.addingTimeInterval(2))
        #expect(repeated.events.isEmpty)
        let freshCounts = TabActivityRecorder.droppingBrowsersObservedLive(
            after: liveAt.addingTimeInterval(3), from: ["Chrome": 6, "Safari": 3], lastLiveObservedAt: ["Chrome": liveAt]
        )
        let fresh = TabActivityRecorder.recordingStep(previous: repeated.nextCounts, current: freshCounts, lastGaugeSampleAt: liveAt, now: liveAt.addingTimeInterval(4))
        #expect(fresh.events.isEmpty)
    }

    @Test("Frequent live snapshots still sample the gauge at most every 5 minutes")
    func liveGaugeThrottle() {
        var lastSample: Date? = nil
        var counts: TabActivityRecorder.TabCounts = ["Chrome": 5]
        var samples = 0
        for second in stride(from: 0, to: 15 * 60, by: 10) {
            let now = start.addingTimeInterval(TimeInterval(second))
            let step = TabActivityRecorder.recordingStep(previous: counts, current: ["Chrome": 5 + second % 2], gaugeBrowsers: ["Chrome"], lastGaugeSampleAt: lastSample, now: now)
            counts = step.nextCounts
            if step.sampledGauge { lastSample = now; samples += 1 }
        }
        #expect(samples == 3)
    }
}

@Suite("Tab stats digest builder")
struct TabStatsDigestBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func counter(_ metric: String, at timestamp: Date) -> MetricEvent {
        MetricEvent(timestamp: timestamp, subject: "Chrome", metric: metric, value: 1, labels: [TabMetric.browserLabel: "Chrome"])
    }

    private func gauge(_ value: Double, at timestamp: Date) -> MetricEvent {
        MetricEvent(timestamp: timestamp, subject: TabMetric.allBrowsersSubject, metric: TabMetric.openCount, value: value)
    }

    @Test("Events split on local midnight, not UTC midnight")
    func dayBoundaries() {
        let events = [
            counter(TabMetric.opened, at: date(26, 23, 59)),
            counter(TabMetric.opened, at: date(27, 0, 1)),
            counter(TabMetric.closed, at: date(27, 6)),
        ]
        let days = TabStatsDigestBuilder.days(from: events, calendar: calendar, now: date(27, 12))
        #expect(days.map(\.day) == ["2026-09-26", "2026-09-27"])
        #expect(days.map(\.opened) == [1, 1])
        #expect(days.map(\.closed) == [0, 1])
    }

    @Test("Hour histogram buckets opens by local hour")
    func hourHistogram() {
        let events = [
            counter(TabMetric.opened, at: date(27, 9, 5)),
            counter(TabMetric.opened, at: date(27, 9, 50)),
            counter(TabMetric.opened, at: date(27, 23, 30)),
        ]
        let day = TabStatsDigestBuilder.days(from: events, calendar: calendar, now: date(28, 1)).first
        #expect(day?.openedByHour.count == 24)
        #expect(day?.openedByHour[9] == 2)
        #expect(day?.openedByHour[23] == 1)
        #expect(day?.openedByHour.reduce(0, +) == 3)
    }

    @Test("Average open is time-weighted and caps sleep gaps; max is the peak")
    func gaugeAverage() {
        // 10 tabs for 5 min, then 20 tabs; the Mac then sleeps 8 hours before 30.
        let events = [
            gauge(10, at: date(27, 9, 0)),
            gauge(20, at: date(27, 9, 5)),
            gauge(30, at: date(27, 17, 5)),
        ]
        let day = TabStatsDigestBuilder.days(from: events, calendar: calendar, now: date(27, 17, 15)).first
        // Holds: 10 -> 5 min, 20 -> capped 10 min, 30 -> 10 min (until now).
        let expected = (10.0 * 5 + 20.0 * 10 + 30.0 * 10) / 25
        #expect(abs((day?.avgOpen ?? 0) - expected) < 0.001)
        #expect(day?.maxOpen == 30)
    }

    @Test("Day keys are Gregorian ISO dates even on a Buddhist or Japanese calendar Mac")
    func dayKeyIgnoresNonGregorianCalendars() {
        for identifier in [Calendar.Identifier.buddhist, .japanese] {
            var localCalendar = Calendar(identifier: identifier)
            localCalendar.timeZone = calendar.timeZone
            let days = TabStatsDigestBuilder.days(
                from: [counter(TabMetric.opened, at: date(26, 23, 59))],
                calendar: localCalendar,
                now: date(27, 12)
            )
            #expect(days.map(\.day) == ["2026-09-26"])
        }
    }

    @Test("Only the last 90 days are kept")
    func retentionWindow() {
        let now = date(27, 12)
        let old = calendar.date(byAdding: .day, value: -90, to: now)!
        let edge = calendar.date(byAdding: .day, value: -89, to: now)!
        let days = TabStatsDigestBuilder.days(from: [counter(TabMetric.opened, at: old), counter(TabMetric.opened, at: edge)], calendar: calendar, now: now)
        #expect(days.count == 1)
        #expect(days.first?.day == TabStatsDigestBuilder.dayKey(edge, calendar: calendar))
    }
}
