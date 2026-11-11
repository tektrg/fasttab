import Foundation
import IndieSavedViews

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

    /// Shared calendar-day buckets (`DayBucket`: Today … Older, Unknown).
    typealias VisitBucket = DayBucket

    static func bucket(for visit: Date?, now: Date, calendar: Calendar) -> VisitBucket {
        DayBucket.bucket(for: visit, now: now, calendar: calendar)
    }

    private static func lastVisitedSections(items: [CustomViewItem], now: Date, calendar: Calendar) -> [CustomViewSection] {
        DayBucket.group(items, now: now, calendar: calendar, date: \.lastVisit).map {
            CustomViewSection(id: "lastVisited.\($0.bucket.rawValue)", title: $0.bucket.title, items: $0.items)
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
