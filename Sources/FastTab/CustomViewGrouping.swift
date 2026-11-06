import Foundation

struct CustomViewSection: Identifiable, Hashable, Sendable {
    /// Stable across refreshes (e.g. "lastVisited.today", "domain.github.com"),
    /// so SwiftUI keeps section identity while items change.
    let id: String
    /// Empty for the single section of `.none`.
    let title: String
    let items: [CustomViewItem]
}

/// Splits a custom view's (already sorted) items into sections. Item order
/// inside each section is preserved. Empty sections are omitted, so empty
/// input yields no sections.
enum CustomViewGrouping {
    static let otherDomainTitle = "Other"

    static func sections(
        items: [CustomViewItem],
        groupBy: CustomViewGroupBy,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [CustomViewSection] {
        guard !items.isEmpty else { return [] }
        switch groupBy {
        case .none:
            return [CustomViewSection(id: "all", title: "", items: items)]
        case .lastVisited:
            return lastVisitedSections(items: items, now: now, calendar: calendar)
        case .domain:
            return domainSections(items: items)
        }
    }

    // MARK: Last visited

    enum VisitBucket: String, CaseIterable, Sendable {
        case today, yesterday, thisWeek, thisMonth, older, unknown

        var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .thisWeek: return "This Week"
            case .thisMonth: return "This Month"
            case .older: return "Older"
            case .unknown: return "Unknown"
            }
        }
    }

    /// Calendar-day buckets relative to `now`: Today (since local midnight,
    /// including anything stamped slightly in the future), Yesterday, This
    /// Week (the 7 days before today), This Month (the 30 days before
    /// today), Older, Unknown (no last visit).
    static func bucket(for visit: Date?, now: Date, calendar: Calendar) -> VisitBucket {
        guard let visit else { return .unknown }
        let startOfToday = calendar.startOfDay(for: now)
        if visit >= startOfToday { return .today }
        func daysBack(_ n: Int) -> Date {
            calendar.date(byAdding: .day, value: -n, to: startOfToday) ?? startOfToday.addingTimeInterval(-Double(n) * 86_400)
        }
        if visit >= daysBack(1) { return .yesterday }
        if visit >= daysBack(7) { return .thisWeek }
        if visit >= daysBack(30) { return .thisMonth }
        return .older
    }

    private static func lastVisitedSections(items: [CustomViewItem], now: Date, calendar: Calendar) -> [CustomViewSection] {
        var buckets: [VisitBucket: [CustomViewItem]] = [:]
        for item in items {
            buckets[bucket(for: item.lastVisit, now: now, calendar: calendar), default: []].append(item)
        }
        return VisitBucket.allCases.compactMap { bucket in
            guard let members = buckets[bucket], !members.isEmpty else { return nil }
            return CustomViewSection(id: "lastVisited.\(bucket.rawValue)", title: bucket.title, items: members)
        }
    }

    // MARK: Domain

    /// One section per bare host (`www.` stripped), largest first, then by
    /// name; items without a web host go to "Other", always last.
    private static func domainSections(items: [CustomViewItem]) -> [CustomViewSection] {
        var byHost: [String: [CustomViewItem]] = [:]
        var other: [CustomViewItem] = []
        for item in items {
            if let host = CustomViewDomain.host(ofURL: item.result.url) {
                byHost[host, default: []].append(item)
            } else {
                other.append(item)
            }
        }
        var sections = byHost
            .sorted { a, b in
                a.value.count != b.value.count ? a.value.count > b.value.count : a.key < b.key
            }
            .map { CustomViewSection(id: "domain.\($0.key)", title: $0.key, items: $0.value) }
        if !other.isEmpty {
            sections.append(CustomViewSection(id: "domain.__other__", title: otherDomainTitle, items: other))
        }
        return sections
    }
}
