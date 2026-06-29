import Foundation

enum BrowserResultType: String, Codable, Hashable, Sendable {
    case tab
    case bookmark
    case history

    var sortPriority: Int {
        switch self {
        case .tab: return 0
        case .bookmark: return 1
        case .history: return 2
        }
    }

    var label: String {
        rawValue.capitalized
    }

    var symbolName: String {
        switch self {
        case .tab: return "rectangle.on.rectangle"
        case .bookmark: return "bookmark"
        case .history: return "clock.arrow.circlepath"
        }
    }

    /// Visual dimming hierarchy for list rows:
    /// tabs = normal, bookmarks = dimmer, history = dimmest.
    var dimmingOpacity: Double {
        switch self {
        case .tab: return 1.0
        case .bookmark: return 0.72
        case .history: return 0.52
        }
    }
}

struct BrowserSearchResult: Identifiable, Codable, Hashable, Sendable {
    let title: String
    let url: String
    let browserName: String
    let type: BrowserResultType
    let timestamp: Date
    let windowIndex: Int?
    let tabIndex: Int?
    let windowName: String?
    let bookmarkID: String?
    let profileName: String?
    let folderPath: String?
    let isCurrentFlowActiveTab: Bool
    let hasMediaIndicator: Bool

    /// Punctuation-stripped match keys, computed once at construction. Per-keystroke
    /// filtering (`matches(query:)`) reuses these instead of re-stripping `title`
    /// and `url` for every result on every keystroke. Derived purely from
    /// `title`/`url`, so excluded from `Codable` — the encoded shape stays identical
    /// to the un-derived fields (forward/backward compatible if this type is ever
    /// persisted); recomputed on decode.
    let normalizedTitleKey: String
    let normalizedURLKey: String

    private enum CodingKeys: String, CodingKey {
        case title, url, browserName, type, timestamp, windowIndex, tabIndex
        case windowName, bookmarkID, profileName, folderPath
        case isCurrentFlowActiveTab, hasMediaIndicator
    }

    init(
        title: String,
        url: String,
        browserName: String,
        type: BrowserResultType,
        timestamp: Date,
        windowIndex: Int? = nil,
        tabIndex: Int? = nil,
        windowName: String? = nil,
        bookmarkID: String? = nil,
        profileName: String? = nil,
        folderPath: String? = nil,
        isCurrentFlowActiveTab: Bool = false,
        hasMediaIndicator: Bool = false
    ) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = normalizedTitle.isEmpty ? url : normalizedTitle
        self.title = resolvedTitle
        self.url = url
        self.browserName = browserName
        self.type = type
        self.timestamp = timestamp
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.windowName = windowName.map(normalizedBrowserWindowName)
        self.bookmarkID = bookmarkID
        self.profileName = profileName
        self.folderPath = folderPath
        self.isCurrentFlowActiveTab = isCurrentFlowActiveTab
        self.hasMediaIndicator = hasMediaIndicator
        self.normalizedTitleKey = stripPunctuation(resolvedTitle)
        self.normalizedURLKey = stripPunctuation(url)
    }

    /// Custom decode that recomputes the derived match keys. Routes through the
    /// designated initializer so key computation lives in exactly one place.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decode(String.self, forKey: .title),
            url: try c.decode(String.self, forKey: .url),
            browserName: try c.decode(String.self, forKey: .browserName),
            type: try c.decode(BrowserResultType.self, forKey: .type),
            timestamp: try c.decode(Date.self, forKey: .timestamp),
            windowIndex: try c.decodeIfPresent(Int.self, forKey: .windowIndex),
            tabIndex: try c.decodeIfPresent(Int.self, forKey: .tabIndex),
            windowName: try c.decodeIfPresent(String.self, forKey: .windowName),
            bookmarkID: try c.decodeIfPresent(String.self, forKey: .bookmarkID),
            profileName: try c.decodeIfPresent(String.self, forKey: .profileName),
            folderPath: try c.decodeIfPresent(String.self, forKey: .folderPath),
            isCurrentFlowActiveTab: try c.decodeIfPresent(Bool.self, forKey: .isCurrentFlowActiveTab) ?? false,
            hasMediaIndicator: try c.decodeIfPresent(Bool.self, forKey: .hasMediaIndicator) ?? false
        )
    }

    var id: String {
        switch type {
        case .tab:
            return [browserName, type.rawValue, String(windowIndex ?? 0), String(tabIndex ?? 0), url].joined(separator: "|")
        case .bookmark:
            return [browserName, type.rawValue, bookmarkID ?? url, profileName ?? ""].joined(separator: "|")
        case .history:
            return [browserName, type.rawValue, url, String(timestamp.timeIntervalSince1970)].joined(separator: "|")
        }
    }

    var secondaryBaseText: String {
        switch type {
        case .bookmark:
            if let folderPath, !folderPath.isEmpty {
                return folderPath
            } else {
                return url
            }
        case .tab, .history:
            return url
        }
    }

    func secondaryMetadata(showWindowName: Bool, showProfileName: Bool) -> [String] {
        var metadata: [String] = []

        if showWindowName,
           type == .tab,
           let windowName,
           !windowName.isEmpty {
            metadata.append(windowName)
        }

        if showProfileName,
           let profileName,
           !profileName.isEmpty {
            metadata.append(profileName)
        }

        return metadata
    }

    func secondaryText(showWindowName: Bool, showProfileName: Bool) -> String {
        let metadata = secondaryMetadata(showWindowName: showWindowName, showProfileName: showProfileName)

        guard !metadata.isEmpty else {
            return secondaryBaseText
        }

        return (metadata + [secondaryBaseText]).joined(separator: " • ")
    }

    func matches(query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let tokens = trimmed
            .components(separatedBy: .whitespaces)
            .map { stripPunctuation($0) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy {
            normalizedTitleKey.localizedCaseInsensitiveContains($0)
                || normalizedURLKey.localizedCaseInsensitiveContains($0)
        }
    }

    /// Short relative-time label ("2m", "3h", "Yest", "3d", "Mar 14") for the
    /// last-visit (history) or last-active (tab) timestamp. Returns nil when
    /// the timestamp is unset (epoch ~0) or the type doesn't carry a meaningful
    /// recency signal (bookmarks).
    var relativeRecencyLabel: String? {
        switch type {
        case .bookmark:
            return nil
        case .tab, .history:
            return relativeRecencyAbbreviation(from: timestamp)
        }
    }

    var tabRecencyKey: String? {
        guard type == .tab else { return nil }
        return makeTabRecencyKey(
            browserName: browserName,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            url: url
        )
    }
}

/// Compact relative-time label. Returns nil for missing/sentinel timestamps.
func relativeRecencyAbbreviation(from date: Date, now: Date = Date()) -> String? {
    let epoch = date.timeIntervalSince1970
    // Treat epoch-0 / pre-2001 sentinels as "no data".
    guard epoch > 978_307_200 else { return nil }

    let delta = now.timeIntervalSince(date)
    if delta < 0 { return "now" }
    if delta < 45 { return "now" }
    if delta < 3_600 {
        return "\(Int((delta / 60).rounded()))m"
    }
    if delta < 6 * 3_600 {
        return "\(Int((delta / 3_600).rounded()))h"
    }

    let calendar = recencyCalendar
    if calendar.isDateInToday(date) {
        return "\(Int((delta / 3_600).rounded()))h"
    }
    if calendar.isDateInYesterday(date) {
        return "Yest"
    }
    if delta < 7 * 86_400 {
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? Int(delta / 86_400)
        return "\(max(1, days))d"
    }
    if delta < 28 * 86_400 {
        return "\(Int((delta / (7 * 86_400)).rounded()))w"
    }

    return recencyMonthDayFormatter.string(from: date)
}

/// Shared calendar/formatter for the relative-recency label. Allocating
/// `Calendar.current` and a `DateFormatter` per row render (one row = one call,
/// many calls per list paint) showed up in the row-render path; these are
/// configured once and only read thereafter. Used only from the main-thread
/// render path, so concurrent-mutation safety isn't a concern.
private let recencyCalendar = Calendar.current
private let recencyMonthDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter
}()

private func stripPunctuation(_ s: String) -> String {
    s.components(separatedBy: .punctuationCharacters).joined()
}

func normalizedBrowserWindowName(_ windowName: String) -> String {
    var normalized = windowName.trimmingCharacters(in: .whitespacesAndNewlines)

    while let first = normalized.unicodeScalars.first,
          browserWindowMediaIndicatorScalars.contains(first.value) {
        normalized.removeFirst()
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    while let last = normalized.unicodeScalars.last,
          browserWindowMediaIndicatorScalars.contains(last.value) {
        normalized.removeLast()
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return normalized
}

func browserWindowMediaIndicatorBelongsToTab(tabTitle: String, windowName: String) -> Bool {
    guard browserWindowNameHasMediaIndicator(windowName) else { return false }

    let normalizedWindowName = normalizedBrowserWindowName(windowName)
    let normalizedTabTitle = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedWindowName.isEmpty, !normalizedTabTitle.isEmpty else { return false }

    if normalizedTabTitle == normalizedWindowName { return true }
    if normalizedTabTitle.contains(normalizedWindowName) { return true }

    let ellipsisParts = normalizedWindowName.split(separator: "…", omittingEmptySubsequences: true)
    guard ellipsisParts.count == 2,
          let prefix = ellipsisParts.first,
          let suffix = ellipsisParts.last else {
        return false
    }

    return normalizedTabTitle.hasPrefix(prefix) && normalizedTabTitle.hasSuffix(suffix)
}

private func browserWindowNameHasMediaIndicator(_ windowName: String) -> Bool {
    let scalars = windowName.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
    guard let first = scalars.first else { return false }
    if browserWindowMediaIndicatorScalars.contains(first.value) { return true }
    guard let last = scalars.last else { return false }
    return browserWindowMediaIndicatorScalars.contains(last.value)
}

private let browserWindowMediaIndicatorScalars: Set<UInt32> = [
    0xFE0F,  // emoji variation selector
    0x1F507, // speaker with cancellation stroke
    0x1F508, // speaker
    0x1F509, // speaker with one sound wave
    0x1F50A  // speaker with three sound waves
]

func makeTabRecencyKey(browserName: String, windowIndex: Int?, tabIndex: Int?, url: String) -> String {
    [browserName, String(windowIndex ?? 0), String(tabIndex ?? 0), url].joined(separator: "|")
}

func sortBrowserSearchResults(_ results: [BrowserSearchResult]) -> [BrowserSearchResult] {
    sortBrowserSearchResults(results, frecencyScore: nil)
}

/// Sort tabs by frecency score (descending) when `frecencyScore` is provided;
/// bookmarks/history continue to sort by timestamp (descending). Type tier is
/// always primary (tabs > bookmarks > history). Frecency only affects the
/// within-tabs ordering, never the cross-tier priority.
///
/// When `frecencyScore` is nil, falls back to legacy timestamp-based ordering
/// (used by cache-refresh paths sorting bookmarks/history only).
///
/// Performance notes:
/// - Tiers are sorted independently and then concatenated. The single-sort
///   variant repeatedly checked `type.sortPriority` on every comparison
///   (n log n times) even though the partitioning is static; per-tier sorts
///   drop that overhead and let each tier use the cheapest comparator it can.
/// - Tab frecency scores are precomputed once per element (decorate / sort /
///   undecorate) so the comparator never re-builds the `browser|profile|url`
///   key string or hits the frecency dict during the n log n compares. For
///   n=500 tabs that's ~500 lookups instead of ~9000.
func sortBrowserSearchResults(
    _ results: [BrowserSearchResult],
    frecencyScore: ((BrowserSearchResult) -> Double)?
) -> [BrowserSearchResult] {
    if results.isEmpty { return results }

    var tabs: [BrowserSearchResult] = []
    var bookmarks: [BrowserSearchResult] = []
    var history: [BrowserSearchResult] = []
    tabs.reserveCapacity(results.count)
    for r in results {
        switch r.type {
        case .tab: tabs.append(r)
        case .bookmark: bookmarks.append(r)
        case .history: history.append(r)
        }
    }

    let sortedTabs = sortTabsTier(tabs, frecencyScore: frecencyScore)
    let sortedBookmarks = sortByTimestampTier(bookmarks)
    let sortedHistory = sortByTimestampTier(history)

    // Concatenate in tier order — tab(0) < bookmark(1) < history(2).
    var out: [BrowserSearchResult] = []
    out.reserveCapacity(sortedTabs.count + sortedBookmarks.count + sortedHistory.count)
    out.append(contentsOf: sortedTabs)
    out.append(contentsOf: sortedBookmarks)
    out.append(contentsOf: sortedHistory)
    return out
}

/// Sort the tabs tier. When `frecencyScore` is provided, precomputes the
/// score for each tab once and sorts the decorated array. Tabs with equal
/// scores fall through to timestamp / browserName / title for a stable feel.
private func sortTabsTier(
    _ tabs: [BrowserSearchResult],
    frecencyScore: ((BrowserSearchResult) -> Double)?
) -> [BrowserSearchResult] {
    if tabs.count <= 1 { return tabs }
    guard let frecencyScore else {
        return sortByTimestampTier(tabs)
    }
    // Decorate-sort-undecorate. Score lookup happens exactly once per tab.
    let decorated: [(score: Double, result: BrowserSearchResult)] =
        tabs.map { (frecencyScore($0), $0) }
    let sorted = decorated.sorted { lhs, rhs in
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.result.timestamp != rhs.result.timestamp {
            return lhs.result.timestamp > rhs.result.timestamp
        }
        if lhs.result.browserName != rhs.result.browserName {
            return lhs.result.browserName.localizedCompare(rhs.result.browserName) == .orderedAscending
        }
        return lhs.result.title.localizedCompare(rhs.result.title) == .orderedAscending
    }
    return sorted.map { $0.result }
}

/// Sort bookmarks/history (or tabs without frecency) by timestamp desc,
/// browserName asc, title asc.
private func sortByTimestampTier(_ items: [BrowserSearchResult]) -> [BrowserSearchResult] {
    if items.count <= 1 { return items }
    return items.sorted { lhs, rhs in
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        if lhs.browserName != rhs.browserName {
            return lhs.browserName.localizedCompare(rhs.browserName) == .orderedAscending
        }
        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }
}

func quickOpenVisibleTabs(from results: [BrowserSearchResult], limit: Int) -> [BrowserSearchResult] {
    Array(results.lazy.filter { !$0.isCurrentFlowActiveTab }.prefix(max(0, limit)))
}

func allQuickOpenTabs(from results: [BrowserSearchResult]) -> [BrowserSearchResult] {
    sortBrowserSearchResults(results.filter { !$0.isCurrentFlowActiveTab })
}

struct QuickOpenDisplayState: Equatable {
    let results: [BrowserSearchResult]
    let includesShowAllTabsItem: Bool
}

func quickOpenDisplayState(
    from results: [BrowserSearchResult],
    limit: Int,
    isShowingAllOpenTabs: Bool
) -> QuickOpenDisplayState {
    let cappedLimit = max(0, limit)
    guard cappedLimit > 0 else {
        return QuickOpenDisplayState(results: [], includesShowAllTabsItem: false)
    }

    if isShowingAllOpenTabs {
        return QuickOpenDisplayState(results: results, includesShowAllTabsItem: false)
    }

    let previewLimit = max(0, cappedLimit - 1)
    if results.count > previewLimit {
        return QuickOpenDisplayState(
            results: Array(results.prefix(previewLimit)),
            includesShowAllTabsItem: true
        )
    }

    return QuickOpenDisplayState(
        results: Array(results.prefix(cappedLimit)),
        includesShowAllTabsItem: false
    )
}
