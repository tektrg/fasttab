import Foundation
import IndieSavedViews

struct CustomViewSection: Identifiable, Hashable, Sendable {
    /// Stable across refreshes (e.g. "all", "domain.github.com"),
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
    static let pinnedSectionID = "pinned"
    static let pinnedSectionTitle = "Pinned"
    static let unpinnedSectionTitle = "Other"
    static let otherDomainTitle = "Other"

    static func sections(
        items: [CustomViewItem],
        groupBy: CustomViewGroupBy,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [CustomViewSection] {
        guard !items.isEmpty else { return [] }
        let pinned = items.filter(\.result.isPinned)
        let rest = items.filter { !$0.result.isPinned }

        var result: [CustomViewSection] = []
        if !pinned.isEmpty {
            result.append(CustomViewSection(id: pinnedSectionID, title: pinnedSectionTitle, items: pinned))
        }
        guard !rest.isEmpty else { return result }

        switch groupBy {
        case .none:
            let title = pinned.isEmpty ? "" : unpinnedSectionTitle
            result.append(CustomViewSection(id: "all", title: title, items: rest))
        case .domain:
            result.append(contentsOf: domainSections(items: rest))
        }
        return result
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
