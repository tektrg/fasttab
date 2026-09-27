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
