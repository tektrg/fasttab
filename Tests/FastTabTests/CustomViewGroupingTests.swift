import Foundation
import Testing
@testable import FastTab

/// `CustomViewGrouping` with a fixed calendar and "now" so day boundaries are
/// deterministic.
struct CustomViewGroupingTests {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }()

    /// 2026-11-06 09:30 local.
    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 9, minute: 30))!

    static func local(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    static func item(_ url: String, title: String, visit: Date?) -> CustomViewItem {
        CustomViewItem(
            result: BrowserSearchResult(
                title: title, url: url, browserName: "Safari", type: .history,
                timestamp: visit ?? Date(timeIntervalSince1970: 0)
            ),
            lastVisit: visit
        )
    }

    private func bucket(_ date: Date?) -> CustomViewGrouping.VisitBucket {
        CustomViewGrouping.bucket(for: date, now: Self.now, calendar: Self.calendar)
    }

    // MARK: Last visited

    @Test func dayBoundaries() {
        #expect(bucket(Self.local(11, 6, 0, 0)) == .today)               // local midnight
        #expect(bucket(Self.now.addingTimeInterval(120)) == .today)       // slightly in the future
        #expect(bucket(Self.local(11, 5, 23, 59, second: 59)) == .yesterday)
        #expect(bucket(Self.local(11, 5, 0, 0)) == .yesterday)
        #expect(bucket(Self.local(11, 4, 23, 59, second: 59)) == .thisWeek)
        #expect(bucket(Self.local(10, 30, 0, 0)) == .thisWeek)            // 7 days before today
        #expect(bucket(Self.local(10, 29, 23, 59, second: 59)) == .thisMonth)
        #expect(bucket(Self.local(10, 7, 0, 0)) == .thisMonth)            // 30 days before today
        #expect(bucket(Self.local(10, 6, 23, 59, second: 59)) == .older)
        #expect(bucket(nil) == .unknown)
    }

    @Test func lastVisitedSectionsInFixedOrderOmittingEmpty() {
        let items = [
            Self.item("https://a.com/1", title: "today", visit: Self.local(11, 6, 8)),
            Self.item("https://a.com/2", title: "unknown", visit: nil),
            Self.item("https://a.com/3", title: "older", visit: Self.local(1, 1)),
            Self.item("https://a.com/4", title: "yesterday", visit: Self.local(11, 5)),
            Self.item("https://a.com/5", title: "today2", visit: Self.local(11, 6, 1)),
        ]
        let sections = CustomViewGrouping.sections(items: items, groupBy: .lastVisited, now: Self.now, calendar: Self.calendar)
        #expect(sections.map(\.title) == ["Today", "Yesterday", "Older", "Unknown"])
        #expect(sections.map(\.id) == ["lastVisited.today", "lastVisited.yesterday", "lastVisited.older", "lastVisited.unknown"])
        #expect(sections[0].items.map(\.result.title) == ["today", "today2"]) // input order kept
    }

    // MARK: Domain

    @Test func domainSectionsByCountThenNameWithOtherLast() {
        let items = [
            Self.item("https://b.com/1", title: "b1", visit: nil),
            Self.item("file:///Users/me/x", title: "file", visit: nil),
            Self.item("https://www.c.com/1", title: "c1", visit: nil),
            Self.item("https://a.com/1", title: "a1", visit: nil),
            Self.item("https://c.com/2", title: "c2", visit: nil),
            Self.item("https://mail.c.com/3", title: "mail", visit: nil),
        ]
        let sections = CustomViewGrouping.sections(items: items, groupBy: .domain, now: Self.now, calendar: Self.calendar)
        #expect(sections.map(\.title) == ["c.com", "a.com", "b.com", "mail.c.com", "Other"])
        #expect(sections[0].items.map(\.result.title) == ["c1", "c2"])
        #expect(sections.last?.items.map(\.result.title) == ["file"])
        #expect(sections.first?.id == "domain.c.com")
    }

    // MARK: None / empty

    @Test func noneIsOneUntitledSection() {
        let items = [Self.item("https://a.com", title: "a", visit: nil), Self.item("https://b.com", title: "b", visit: nil)]
        let sections = CustomViewGrouping.sections(items: items, groupBy: .none, now: Self.now, calendar: Self.calendar)
        #expect(sections.count == 1)
        #expect(sections[0].title.isEmpty)
        #expect(sections[0].items == items)
    }

    @Test(arguments: CustomViewGroupBy.allCases)
    func emptyInputHasNoSections(groupBy: CustomViewGroupBy) {
        #expect(CustomViewGrouping.sections(items: [], groupBy: groupBy, now: Self.now, calendar: Self.calendar).isEmpty)
    }
}
