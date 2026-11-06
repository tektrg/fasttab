import Foundation
import IndieSearch

/// One row of a custom view: the result plus its resolved last-visit time
/// (which, for bookmarks, comes from a history join — not the result itself).
struct CustomViewItem: Identifiable, Hashable, Sendable {
    let result: BrowserSearchResult
    /// Nil = unknown (never-activated tab, bookmark with no history hit).
    let lastVisit: Date?
    var id: String { result.id }
}

/// Evaluates a `CustomView`'s structured filters over candidate results (open
/// tabs + bookmarks + history — see `BrowserTabService.customViewCandidates()`).
/// Pure and synchronous; the semantic (AI) filter is not applied here.
enum CustomViewFilter {
    /// Timestamps before 2000-01-01 are sentinels, not visits: Chromium tabs
    /// never activated while FastTab watched get epoch 0
    /// (`ChromiumBackend` tab timestamp), Safari bookmarks carry epoch 0.
    static let lastVisitFloor = Date(timeIntervalSince1970: 946_684_800)

    /// Most recent history visit per page (`pageKey`).
    typealias HistoryIndex = [String: Date]

    // MARK: Last visit

    /// Page identity for joining/deduping: scheme-less, `www.`-less host
    /// (+ non-default port) + path without trailing slash, plus the query.
    /// Fragment is dropped. Keeps the query so distinct `?v=` pages stay apart.
    static func pageKey(forURL url: String) -> String {
        let identity = historyPageIdentity(forURL: url)
        guard let query = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.percentEncodedQuery,
              !query.isEmpty else { return identity }
        return identity + "?" + query
    }

    /// Builds the bookmark → last-visit lookup from the history rows in
    /// `candidates`. Build once per evaluation.
    static func makeHistoryIndex(from candidates: [BrowserSearchResult]) -> HistoryIndex {
        var index: HistoryIndex = [:]
        for item in candidates where item.type == .history && item.timestamp >= lastVisitFloor {
            let key = pageKey(forURL: item.url)
            if let existing = index[key], existing >= item.timestamp { continue }
            index[key] = item.timestamp
        }
        return index
    }

    /// Tab → its last-active time; history → its visit time; bookmark → the
    /// newest history visit of the same page (any browser/profile in the
    /// index). Nil = unknown.
    static func lastVisit(for item: BrowserSearchResult, historyIndex: HistoryIndex) -> Date? {
        switch item.type {
        case .tab, .history:
            return item.timestamp >= lastVisitFloor ? item.timestamp : nil
        case .bookmark:
            return historyIndex[pageKey(forURL: item.url)]
        case .sent, .fastTabList:
            return nil
        }
    }

    // MARK: Apply

    /// Matching items, deduped and sorted by last visit (newest first,
    /// unknown last, then title, then id for a stable order).
    static func evaluate(
        _ view: CustomView,
        candidates: [BrowserSearchResult],
        now: Date = Date()
    ) -> [CustomViewItem] {
        let matcher = Matcher(view: view)
        let historyIndex = makeHistoryIndex(from: candidates)

        var tabs: [CustomViewItem] = []
        var bookmarks: [CustomViewItem] = []
        // History deduped by page: keep the newest row.
        var historyByPage: [String: (order: Int, item: CustomViewItem)] = [:]

        for (order, candidate) in candidates.enumerated() {
            guard matcher.matchesStructure(candidate) else { continue }
            let visit = lastVisit(for: candidate, historyIndex: historyIndex)
            guard matcher.matchesTime(visit, now: now) else { continue }
            let item = CustomViewItem(result: candidate, lastVisit: visit)
            switch candidate.type {
            case .tab: tabs.append(item)
            case .bookmark: bookmarks.append(item)
            case .history:
                let key = pageKey(forURL: candidate.url)
                if let existing = historyByPage[key],
                   (existing.item.lastVisit ?? .distantPast) >= (visit ?? .distantPast) { continue }
                historyByPage[key] = (order, item)
            case .sent, .fastTabList:
                continue
            }
        }

        // A bookmark or history row for a page that's open (and shown) is
        // redundant; the open tab is the actionable row. Tabs themselves are
        // never dropped, and without shown tabs nothing is suppressed.
        var openPages = Set(tabs.map { pageKey(forURL: $0.result.url) })
        // "Not pinned" hides pinned pages, so a pinned tab's bookmark or
        // history row must not stand in for the tab it filtered out.
        if view.pinned == .exclude {
            for candidate in candidates where candidate.type == .tab && candidate.isPinned {
                openPages.insert(pageKey(forURL: candidate.url))
            }
        }
        if !openPages.isEmpty {
            bookmarks.removeAll { openPages.contains(pageKey(forURL: $0.result.url)) }
        }
        let history = historyByPage
            .filter { !openPages.contains($0.key) }
            .values.sorted { $0.order < $1.order }
            .map(\.item)

        return sorted(tabs + bookmarks + history)
    }

    /// `evaluate` without the resolved dates.
    static func apply(
        _ view: CustomView,
        to candidates: [BrowserSearchResult],
        now: Date = Date()
    ) -> [BrowserSearchResult] {
        evaluate(view, candidates: candidates, now: now).map(\.result)
    }

    static func sorted(_ items: [CustomViewItem]) -> [CustomViewItem] {
        items.sorted { a, b in
            switch (a.lastVisit, b.lastVisit) {
            case let (x?, y?) where x != y: return x > y
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                if a.result.normalizedTitleKey != b.result.normalizedTitleKey {
                    return a.result.normalizedTitleKey < b.result.normalizedTitleKey
                }
                return a.result.id < b.result.id
            }
        }
    }

    // MARK: Matcher

    /// A view's constraints, normalized once so per-candidate checks are
    /// plain set/string comparisons.
    struct Matcher {
        let types: Set<BrowserResultType>
        let profiles: Set<String>
        let domains: [String]
        let keywordWords: [String]
        let rule: LastVisitedRule
        let pinned: PinnedRule

        init(view: CustomView) {
            types = view.effectiveTypes
            profiles = Set(view.profiles.compactMap {
                let p = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return p.isEmpty ? nil : p
            })
            var seen = Set<String>()
            domains = view.domains.compactMap(CustomViewDomain.normalize).filter { seen.insert($0).inserted }
            keywordWords = searchWords(in: view.keywords)
            rule = view.lastVisited
            pinned = view.pinned
        }

        /// Everything except the time rule (which needs the resolved visit).
        func matchesStructure(_ item: BrowserSearchResult) -> Bool {
            guard types.contains(item.type), pinned.matches(item) else { return false }
            if !profiles.isEmpty {
                guard let profile = item.profileName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      profiles.contains(profile) else { return false }
            }
            if !domains.isEmpty {
                guard let host = CustomViewDomain.host(ofURL: item.url),
                      domains.contains(where: { CustomViewDomain.host(host, isWithin: $0) }) else { return false }
            }
            if !keywordWords.isEmpty, !item.matches(words: keywordWords) { return false }
            return true
        }

        func matchesTime(_ visit: Date?, now: Date) -> Bool {
            switch rule {
            case .any:
                return true
            case .within(let seconds):
                guard let visit else { return false }
                return now.timeIntervalSince(visit) <= seconds
            case .olderThan(let seconds):
                guard let visit else { return false }
                return now.timeIntervalSince(visit) > seconds
            }
        }
    }
}
