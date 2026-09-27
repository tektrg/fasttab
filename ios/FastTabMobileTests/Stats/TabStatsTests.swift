import XCTest
import FastTabSync
@testable import FastTabMobile

@MainActor
final class TabStatsCacheTests: XCTestCase {
    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tabstats-\(UUID().uuidString).json")
    }

    func testCacheWrittenBeforeTabStatsExistedStillDecodes() throws {
        let device = SyncedDevice(id: "mac", name: "Mac", modelName: "MacBook", appVersion: "1.0")
        let current = try JSONEncoder().encode(CachedSyncState(devices: [device]))
        var oldShape = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        oldShape.removeValue(forKey: "tabStats")
        let oldJSON = try JSONSerialization.data(withJSONObject: oldShape)

        let state = try JSONDecoder().decode(CachedSyncState.self, from: oldJSON)
        XCTAssertEqual(state.devices.map(\.id), ["mac"])
        XCTAssertTrue(state.tabStats.isEmpty)
    }

    func testOneUnreadableTabStatsEntryDropsOnlyThatEntry() throws {
        let good = SyncedTabStats(deviceID: "mac-a", timeZoneID: "UTC", days: [TabDay(day: "2026-09-27", opened: 5)])
        let device = SyncedDevice(id: "mac-a", name: "Mac", modelName: "MacBook", appVersion: "1.0")
        let encoded = try JSONEncoder().encode(CachedSyncState(devices: [device], tabStats: ["mac-a": good]))
        var shape = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var tabStats = try XCTUnwrap(shape["tabStats"] as? [String: Any])
        tabStats["mac-b"] = ["unexpected": true]
        shape["tabStats"] = tabStats

        let state = try JSONDecoder().decode(CachedSyncState.self, from: JSONSerialization.data(withJSONObject: shape))
        XCTAssertEqual(state.devices.count, 1)
        XCTAssertEqual(Array(state.tabStats.keys), ["mac-a"])
    }

    func testStatsViewModelChartsTheDigestJustSynced() {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = LocalCache(customFileURL: cacheURL)
        let suite = "StatsViewModelTabsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let viewModel = StatsViewModel(
            recorder: ReadingStatsRecorder(log: InMemoryMetricEventLog(), defaults: defaults),
            topicResolver: ReadingTopicResolver(defaults: defaults),
            localCache: cache,
            calendar: .current
        )
        let today = DateFormatter()
        today.dateFormat = "yyyy-MM-dd"
        today.locale = Locale(identifier: "en_US_POSIX")
        cache.updateTabStats(SyncedTabStats(deviceID: "mac-a", timeZoneID: "UTC", days: [TabDay(day: today.string(from: Date()), opened: 7)]))
        XCTAssertEqual(viewModel.tabs.openedByDay.map(\.value), [7])
    }

    func testTabStatsRoundTripAndAreDroppedWithTheirMac() throws {
        let cacheURL = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cache = LocalCache(customFileURL: cacheURL)
        cache.updateTabStats(SyncedTabStats(deviceID: "mac-a", timeZoneID: "UTC", days: [TabDay(day: "2026-09-27", opened: 5)]))
        cache.updateTabStats(SyncedTabStats(deviceID: "mac-b", timeZoneID: "UTC", days: []))
        cache.saveToDisk()

        let reloaded = LocalCache(customFileURL: cacheURL)
        XCTAssertEqual(reloaded.state.tabStats["mac-a"]?.days.first?.opened, 5)

        reloaded.removeTabStats(recordName: SyncedTabStats.recordName(deviceID: "mac-b"))
        reloaded.removeDevice(id: "mac-a")
        XCTAssertTrue(reloaded.state.tabStats.isEmpty)
    }
}

final class TabStatsSummaryTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ day: String, hour: Int = 12) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))!
    }

    private func hours(_ counts: [Int: Int]) -> [Int] {
        (0..<24).map { counts[$0] ?? 0 }
    }

    func testMacsAreSummedPerDayAndSlot() {
        let macA = SyncedTabStats(deviceID: "a", timeZoneID: "UTC", days: [
            TabDay(day: "2026-09-21", opened: 4, avgOpen: 20, openedByHour: hours([9: 3, 14: 1])),
            TabDay(day: "2026-09-22", opened: 2, avgOpen: 18, openedByHour: hours([9: 2]))
        ])
        let macB = SyncedTabStats(deviceID: "b", timeZoneID: "UTC", days: [
            TabDay(day: "2026-09-21", opened: 6, avgOpen: 30, openedByHour: hours([14: 6]))
        ])
        let summary = TabStatsSummary.make(from: [macA, macB], now: date("2026-09-22"), calendar: calendar)

        XCTAssertEqual(summary.openedByDay.map(\.value), [10, 2])
        XCTAssertEqual(summary.averageOpenByDay.map(\.value), [50, 18])
        XCTAssertEqual(summary.openedByDay.first?.day, calendar.startOfDay(for: date("2026-09-21")))
        XCTAssertEqual(summary.busiestHour, 14)
        XCTAssertEqual(summary.busiestWeekday, 2) // 2026-09-21 is a Monday
    }

    func testDaysOutsideTheChartedWindowAreLeftOut() {
        let mac = SyncedTabStats(deviceID: "a", timeZoneID: "UTC", days: [
            TabDay(day: "2026-06-01", opened: 9, avgOpen: 5, openedByHour: hours([8: 9]))
        ])
        let summary = TabStatsSummary.make(from: [mac], now: date("2026-09-22"), calendar: calendar)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertNil(summary.busiestHour)
    }

    func testRecentMeanSkipsTodayAndCountsMissingDaysAsZero() {
        let values = ["2026-09-18", "2026-09-20", "2026-09-22"].map {
            TabStatsSummary.DayValue(day: calendar.startOfDay(for: date($0)), value: 10)
        }
        // Complete days 09-18...09-21 (4 days): 10 + 0 + 10 + 0.
        XCTAssertEqual(TabStatsSummary.recentMean(values, days: 7, missingDaysAsZero: true, now: date("2026-09-22"), calendar: calendar), 5)
        // A level (open tabs): a day without data is the Mac being off, not zero tabs.
        XCTAssertEqual(TabStatsSummary.recentMean(values, days: 7, missingDaysAsZero: false, now: date("2026-09-22"), calendar: calendar), 10)
        let onlyToday = [TabStatsSummary.DayValue(day: calendar.startOfDay(for: date("2026-09-22")), value: 3)]
        XCTAssertEqual(TabStatsSummary.recentMean(onlyToday, days: 7, missingDaysAsZero: true, now: date("2026-09-22"), calendar: calendar), 3)
    }

    func testBuddhistCalendarPhoneReadsTheMacsGregorianDates() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let mac = SyncedTabStats(deviceID: "a", timeZoneID: "Asia/Bangkok", days: [
            TabDay(day: "2026-09-21", opened: 4, avgOpen: 20, openedByHour: hours([9: 4]))
        ])
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = buddhist.timeZone
        let now = gregorian.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!

        let summary = TabStatsSummary.make(from: [mac], now: now, calendar: buddhist)

        XCTAssertEqual(summary.openedByDay.map(\.value), [4])
        XCTAssertEqual(summary.openedByDay.first?.day, gregorian.date(from: DateComponents(year: 2026, month: 9, day: 21)))
        XCTAssertEqual(summary.busiestHour, 9)
        XCTAssertEqual(TabStatsSummary.dayKey(for: now, calendar: buddhist), "2026-09-22")
    }

    func testDayKeysRejectMalformedAndImpossibleDates() {
        for key in ["2026-02-30", "2569-9-21", "21/09/2026", "", "2026-09-21T00:00"] {
            XCTAssertNil(TabStatsSummary.dayStart(forKey: key, calendar: calendar), key)
        }
        XCTAssertEqual(TabStatsSummary.dayStart(forKey: "2026-09-21", calendar: calendar), calendar.startOfDay(for: date("2026-09-21")))
    }

    /// Hours are the Mac's local hours, summed by index: a spring-forward day on the phone
    /// (no 2 AM) must not move a Mac's 2 AM tabs into 3 AM.
    func testHoursKeepTheirIndexOnADaylightSavingDay() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let mac = SyncedTabStats(deviceID: "a", timeZoneID: "Asia/Ho_Chi_Minh", days: [
            TabDay(day: "2026-03-08", opened: 5, openedByHour: hours([2: 5]))
        ])
        let now = newYork.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!

        let summary = TabStatsSummary.make(from: [mac], now: now, calendar: newYork)

        XCTAssertEqual(summary.busiestHour, 2)
        XCTAssertEqual(summary.openedByHour.first { $0.slot == 2 }?.value, 5)
        XCTAssertEqual(summary.openedByHour.count, 24)
    }

    /// Macs in different time zones meet by calendar date, and their average open tabs add up.
    func testMacsInDifferentTimeZonesMeetByDate() {
        let hanoi = SyncedTabStats(deviceID: "a", timeZoneID: "Asia/Ho_Chi_Minh", days: [TabDay(day: "2026-09-21", opened: 3, avgOpen: 12)])
        let seattle = SyncedTabStats(deviceID: "b", timeZoneID: "America/Los_Angeles", days: [TabDay(day: "2026-09-21", opened: 2, avgOpen: 8)])
        let summary = TabStatsSummary.make(from: [hanoi, seattle], now: date("2026-09-22"), calendar: calendar)
        XCTAssertEqual(summary.averageOpenByDay.map(\.value), [20])
        XCTAssertEqual(summary.openedByDay.map(\.value), [5])
    }

    func testNoDigestsIsEmpty() {
        XCTAssertTrue(TabStatsSummary.make(from: [], now: Date(), calendar: calendar).isEmpty)
    }
}
