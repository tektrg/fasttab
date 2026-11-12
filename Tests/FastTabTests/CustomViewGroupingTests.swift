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

    @Test func lastVisitedGroupingIsGone() {
        #expect(!CustomViewGroupBy.allCases.map(\.rawValue).contains("lastVisited"))
        #expect(CustomViewGroupBy.allCases.map(\.displayName) == ["None", "Domain"])
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
