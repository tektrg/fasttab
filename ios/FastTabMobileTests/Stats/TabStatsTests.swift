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

    func testDaysOutsideTheChartedWindowOnlyFeedSlots() {
        let mac = SyncedTabStats(deviceID: "a", timeZoneID: "UTC", days: [
            TabDay(day: "2026-06-01", opened: 9, avgOpen: 5, openedByHour: hours([8: 9]))
        ])
        let summary = TabStatsSummary.make(from: [mac], now: date("2026-09-22"), calendar: calendar)
        XCTAssertTrue(summary.openedByDay.isEmpty)
        XCTAssertEqual(summary.busiestHour, 8)
    }

    func testNoDigestsIsEmpty() {
        XCTAssertTrue(TabStatsSummary.make(from: [], now: Date(), calendar: calendar).isEmpty)
    }
}
