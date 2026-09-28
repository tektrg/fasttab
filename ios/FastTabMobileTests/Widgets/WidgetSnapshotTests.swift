import XCTest
import FastTabSync
import IndieMetrics
@testable import FastTabMobile

@MainActor
final class WidgetSnapshotTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func day(_ daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now))!
    }

    private func recent(_ id: String, daysAgo: Double) -> RecentAddedItem {
        let url = URL(string: "https://www.\(id).com/post")!
        return RecentAddedItem(
            id: id, title: "Post \(id)", url: url, domain: url.host()!,
            date: now.addingTimeInterval(-daysAgo * 86_400), source: .savedOnIPhone(linkID: id)
        )
    }

    // MARK: - Up next

    func testUpNextKeepsFeedOrderSkipsStartedArticlesAndCapsAtThree() {
        let items = ["a", "b", "c", "d", "e"].enumerated().map { recent($0.element, daysAgo: Double($0.offset)) }
        let progress: [String: Double] = ["https://www.b.com/post": 0.4, "https://www.c.com/post": 0.02]

        let upNext = WidgetSnapshotBuilder.upNext(from: items) { progress[$0.absoluteString] ?? 0 }

        XCTAssertEqual(upNext.map(\.title), ["Post a", "Post c", "Post d"])
        XCTAssertEqual(upNext.first?.domain, "a.com")
    }

    func testLinkFallsBackToDomainForBlankTitle() {
        let link = WidgetSnapshotBuilder.link(title: "  ", url: URL(string: "https://www.example.com/x")!)
        XCTAssertEqual(link.title, "example.com")
    }

    // MARK: - Reading ring

    private func words(_ value: Double, daysAgo: Int, hour: Int = 10) -> MetricEvent {
        MetricEvent(timestamp: day(daysAgo).addingTimeInterval(Double(hour) * 3600), subject: "s", metric: ReadingMetric.words, value: value)
    }

    func testReadingSumsWordsPerDayAndIgnoresOtherMetrics() {
        let events = [
            words(1_000, daysAgo: 0, hour: 1), words(500, daysAgo: 0, hour: 20), words(700, daysAgo: 2),
            MetricEvent(timestamp: now, subject: "s", metric: ReadingMetric.finished, value: 1),
        ]
        let reading = WidgetSnapshotBuilder.reading(from: events, dailyWordGoal: 3_000, now: now, calendar: calendar)

        XCTAssertEqual(reading.wordsByDay, [day(0): 1_500, day(2): 700])
        XCTAssertEqual(reading.dailyWordGoal, 3_000)
    }

    func testRingFractionClampsAndClosesAtGoal() {
        XCTAssertEqual(ReadingRingDay(dayStart: now, words: 1_500, goal: 3_000).fraction, 0.5)
        XCTAssertEqual(ReadingRingDay(dayStart: now, words: 9_000, goal: 3_000).fraction, 1)
        XCTAssertTrue(ReadingRingDay(dayStart: now, words: 3_000, goal: 3_000).isClosed)
        XCTAssertFalse(ReadingRingDay(dayStart: now, words: 2_999, goal: 3_000).isClosed)
    }

    func testStreakCountsTodayOnceClosed() {
        let reading = WidgetSnapshot.Reading(dailyWordGoal: 1_000, wordsByDay: [day(0): 1_200, day(1): 1_000, day(2): 5_000, day(4): 2_000])
        let progress = ReadingRingProgress.make(from: reading, now: now, calendar: calendar)

        XCTAssertTrue(progress.today.isClosed)
        XCTAssertEqual(progress.streak, 3)
    }

    func testOpenTodayDoesNotBreakYesterdaysStreak() {
        let reading = WidgetSnapshot.Reading(dailyWordGoal: 1_000, wordsByDay: [day(0): 200, day(1): 1_000, day(2): 1_000])
        let progress = ReadingRingProgress.make(from: reading, now: now, calendar: calendar)

        XCTAssertEqual(progress.today.words, 200)
        XCTAssertEqual(progress.streak, 2)
    }

    func testMissedDayResetsStreak() {
        let reading = WidgetSnapshot.Reading(dailyWordGoal: 1_000, wordsByDay: [day(2): 1_000, day(3): 1_000])
        XCTAssertEqual(ReadingRingProgress.make(from: reading, now: now, calendar: calendar).streak, 0)
    }

    func testWeekRowIsSevenDaysOldestFirstEndingToday() {
        let reading = WidgetSnapshot.Reading(dailyWordGoal: 1_000, wordsByDay: [day(6): 500, day(0): 250])
        let week = ReadingRingProgress.make(from: reading, now: now, calendar: calendar).lastSevenDays

        XCTAssertEqual(week.map(\.dayStart), (0..<7).reversed().map(day))
        XCTAssertEqual(week.first?.fraction, 0.5)
        XCTAssertEqual(week.last?.fraction, 0.25)
    }

    func testNewDayStartsWithAnEmptyRing() {
        let reading = WidgetSnapshot.Reading(dailyWordGoal: 1_000, wordsByDay: [day(0): 1_000])
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let progress = ReadingRingProgress.make(from: reading, now: tomorrow, calendar: calendar)

        XCTAssertEqual(progress.today.words, 0)
        XCTAssertEqual(progress.streak, 1)
    }

    // MARK: - Shuffle

    func testShuffleMirrorsTheDecksTopCard() {
        let tab = SyncedTab(id: "t1", deviceID: "mac", browserName: "Chrome", title: "Top card", url: "https://www.top.com/a")
        let deck = [
            RandomCardItem(id: "tab|t1", title: "Top card", url: URL(string: tab.url)!, source: .openTab(tab: tab)),
            RandomCardItem(id: "tab|t2", title: "Second", url: URL(string: "https://second.com")!, source: .openTab(tab: tab)),
        ]
        let fileName = WidgetSnapshotBuilder.thumbnailFileName(for: deck[0])
        let shuffle = WidgetSnapshotBuilder.shuffle(from: deck[0], thumbnailFileName: fileName)

        XCTAssertEqual(shuffle.item.url, deck[0].url)
        XCTAssertEqual(shuffle.item.title, "Top card")
        XCTAssertEqual(shuffle.badge, "Open tab · Chrome")
        XCTAssertNil(shuffle.highlightID)
        XCTAssertEqual(fileName, "shuffle_tab_t1.jpg")
        XCTAssertNotEqual(fileName, WidgetSnapshotBuilder.thumbnailFileName(for: deck[1]))
    }

    // MARK: - Open tabs

    func testOpenTabsCountsAllAndListsThreeMostRecentWebTabs() {
        func tab(_ id: String, _ url: String, minutesAgo: Double) -> SyncedTab {
            SyncedTab(id: id, deviceID: "mac", browserName: "Chrome", title: "Tab \(id)", url: url, timestamp: now.addingTimeInterval(-minutesAgo * 60))
        }
        let tabs = [
            tab("old", "https://old.com", minutesAgo: 90),
            tab("new", "https://new.com", minutesAgo: 1),
            tab("settings", "chrome://settings", minutesAgo: 0),
            tab("mid", "https://mid.com", minutesAgo: 30),
            tab("older", "https://older.com", minutesAgo: 200),
        ]
        let openTabs = WidgetSnapshotBuilder.openTabs(from: tabs)

        XCTAssertEqual(openTabs.totalCount, 5)
        XCTAssertEqual(openTabs.recent.map(\.title), ["Tab new", "Tab mid", "Tab old"])
    }

    // MARK: - Persistence + deep links

    func testSnapshotRoundTripsThroughDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget_snapshot_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = WidgetSnapshot(
            upNext: [WidgetSnapshotBuilder.link(title: "A", url: URL(string: "https://a.com")!)],
            reading: WidgetSnapshot.Reading(dailyWordGoal: 3_000, wordsByDay: [day(0): 42]),
            shuffle: nil,
            openTabs: WidgetSnapshot.OpenTabs(totalCount: 2, recent: []),
            writtenAt: now
        )
        try WidgetSnapshotStore.save(snapshot, to: url)
        XCTAssertEqual(WidgetSnapshotStore.load(from: url), snapshot)
    }

    func testDeepLinksRoundTrip() {
        let links: [WidgetDeepLink] = [
            .read(url: URL(string: "https://a.com/x?q=1&b=2")!, title: "A & B", highlightID: "h1"),
            .read(url: URL(string: "https://a.com")!, title: "", highlightID: nil),
            .stats,
            .tabs,
        ]
        for link in links {
            XCTAssertEqual(WidgetDeepLink(url: link.url), link, link.url.absoluteString)
        }
        XCTAssertNil(WidgetDeepLink(url: URL(string: "https://fasttab.app/stats")!))
    }
}
