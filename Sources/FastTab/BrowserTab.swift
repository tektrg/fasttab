import Foundation
import CommandBarKit
import IndieSearch

enum BrowserResultType: String, Codable, Hashable, Sendable {
    case sent
    case tab
    case bookmark
    case history

    var sortPriority: Int {
        switch self {
        case .sent: return -1
        case .tab: return 0
        case .bookmark: return 1
        case .history: return 2
        }
    }

    var label: String {
        switch self {
        case .sent: return "From iPhone"
        default: return rawValue.capitalized
        }
    }

    var symbolName: String {
        switch self {
        case .sent: return "iphone.and.arrow.forward"
        case .tab: return "rectangle.on.rectangle"
        case .bookmark: return "bookmark"
        case .history: return "clock.arrow.circlepath"
        }
    }

    /// Visual dimming hierarchy for list rows:
    /// sent/tabs = normal, bookmarks = dimmer, history = dimmest.
    var dimmingOpacity: Double {
        switch self {
        case .sent, .tab: return 1.0
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
    /// Stable browser tab ID from the companion extension. Set only on
    /// extension-sourced tabs; `activateTab`/`closeTab` prefer it and fall back
    /// to `windowIndex`/`tabIndex`.
    let tabID: Int?
    let isAudible: Bool
    let isMuted: Bool
    let isPinned: Bool
    let isDiscarded: Bool
    let tabGroupTitle: String?
    /// True when this tab is currently audible (or was within the last few
    /// seconds — see `annotatingPinnedAudibleTabs`), regardless of what site
    /// it's on. Extension-sourced tabs only; AppleScript-backend tabs never
    /// set this. Drives the sticky-to-top behavior in `sortTabsTier`.
    let isPinnedAudibleTab: Bool
    /// True when this result represents a closed (ghost) pinned tab that
    /// remains persistent in FastTab's Stack slots.
    let isGhost: Bool

    /// Folded match keys (lowercased, accent-stripped, punctuation-stripped),
    /// computed once at construction. Per-keystroke filtering (`matches(query:)`)
    /// reuses these instead of re-folding `title` and `url` for every result on
    /// every keystroke. Derived purely from
    /// `title`/`url`, so excluded from `Codable` — the encoded shape stays identical
    /// to the un-derived fields (forward/backward compatible if this type is ever
    /// persisted); recomputed on decode.
    let normalizedTitleKey: String
    let normalizedURLKey: String
    /// Cross-type duplicate-page key (see `duplicatePageDedupeKey`), computed
    /// once at construction. `deduplicatingSamePages` runs twice per fetch
    /// (phase 1, then phase 2 once history lands) over largely the same
    /// tabs/bookmarks — recomputing this by re-parsing `url` with
    /// `URLComponents` both times was pure waste.
    let duplicateDedupeKey: String

    private enum CodingKeys: String, CodingKey {
        case title, url, browserName, type, timestamp, windowIndex, tabIndex
        case windowName, bookmarkID, profileName, folderPath
        case isCurrentFlowActiveTab, hasMediaIndicator
        case tabID, isAudible, isMuted, isPinned, isDiscarded, tabGroupTitle
        case isPinnedAudibleTab
        case isGhost
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
        hasMediaIndicator: Bool = false,
        tabID: Int? = nil,
        isAudible: Bool = false,
        isMuted: Bool = false,
        isPinned: Bool = false,
        isDiscarded: Bool = false,
        tabGroupTitle: String? = nil,
        isPinnedAudibleTab: Bool = false,
        isGhost: Bool = false
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
        self.tabID = tabID
        self.isAudible = isAudible
        self.isMuted = isMuted
        self.isPinned = isPinned
        self.isDiscarded = isDiscarded
        self.tabGroupTitle = tabGroupTitle
        self.isPinnedAudibleTab = isPinnedAudibleTab
        self.isGhost = isGhost
        self.normalizedTitleKey = foldForMatching(resolvedTitle)
        self.normalizedURLKey = foldURLForMatching(url)
        self.duplicateDedupeKey = [
            browserName,
            profileName ?? "",
            foldForMatching(strippingLeadingCountBadge(resolvedTitle)),
            historyPageIdentity(forURL: url)
        ].joined(separator: "|")
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
            hasMediaIndicator: try c.decodeIfPresent(Bool.self, forKey: .hasMediaIndicator) ?? false,
            tabID: try c.decodeIfPresent(Int.self, forKey: .tabID),
            isAudible: try c.decodeIfPresent(Bool.self, forKey: .isAudible) ?? false,
            isMuted: try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            isPinned: try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            isDiscarded: try c.decodeIfPresent(Bool.self, forKey: .isDiscarded) ?? false,
            tabGroupTitle: try c.decodeIfPresent(String.self, forKey: .tabGroupTitle),
            isPinnedAudibleTab: try c.decodeIfPresent(Bool.self, forKey: .isPinnedAudibleTab) ?? false,
            isGhost: try c.decodeIfPresent(Bool.self, forKey: .isGhost) ?? false
        )
    }

    /// Copy of this result with `isPinnedAudibleTab` overridden. Used only by
    /// `annotatingPinnedAudibleTabs` to apply the hysteresis grace window on
    /// top of the raw (this-instant) value set at construction time.
    func settingPinnedAudible(_ value: Bool) -> BrowserSearchResult {
        guard value != isPinnedAudibleTab else { return self }
        return BrowserSearchResult(
            title: title,
            url: url,
            browserName: browserName,
            type: type,
            timestamp: timestamp,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            windowName: windowName,
            bookmarkID: bookmarkID,
            profileName: profileName,
            folderPath: folderPath,
            isCurrentFlowActiveTab: isCurrentFlowActiveTab,
            hasMediaIndicator: hasMediaIndicator,
            tabID: tabID,
            isAudible: isAudible,
            isMuted: isMuted,
            isPinned: isPinned,
            isDiscarded: isDiscarded,
            tabGroupTitle: tabGroupTitle,
            isPinnedAudibleTab: value,
            isGhost: isGhost
        )
    }

    /// Copy of this result with `isMuted` overridden and `isPinnedAudibleTab`
    /// recomputed the same way `ExtensionBackedBackend` derives it (audible
    /// AND not muted). Used for optimistic UI feedback right after the user
    /// mutes a tab from the "Playing now" strip, before the next extension
    /// poll confirms the real state.
    func settingMuted(_ value: Bool) -> BrowserSearchResult {
        guard value != isMuted else { return self }
        return BrowserSearchResult(
            title: title,
            url: url,
            browserName: browserName,
            type: type,
            timestamp: timestamp,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            windowName: windowName,
            bookmarkID: bookmarkID,
            profileName: profileName,
            folderPath: folderPath,
            isCurrentFlowActiveTab: isCurrentFlowActiveTab,
            hasMediaIndicator: isAudible && !value,
            tabID: tabID,
            isAudible: isAudible,
            isMuted: value,
            isPinned: isPinned,
            isDiscarded: isDiscarded,
            tabGroupTitle: tabGroupTitle,
            isPinnedAudibleTab: isAudible && !value,
            isGhost: isGhost
        )
    }

    func settingPinned(_ value: Bool) -> BrowserSearchResult {
        guard value != isPinned else { return self }
        return BrowserSearchResult(
            title: title,
            url: url,
            browserName: browserName,
            type: type,
            timestamp: timestamp,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            windowName: windowName,
            bookmarkID: bookmarkID,
            profileName: profileName,
            folderPath: folderPath,
            isCurrentFlowActiveTab: isCurrentFlowActiveTab,
            hasMediaIndicator: hasMediaIndicator,
            tabID: tabID,
            isAudible: isAudible,
            isMuted: isMuted,
            isPinned: value,
            isDiscarded: isDiscarded,
            tabGroupTitle: tabGroupTitle,
            isPinnedAudibleTab: isPinnedAudibleTab,
            isGhost: isGhost
        )
    }

    func settingTimestamp(_ value: Date) -> BrowserSearchResult {
        guard value != timestamp else { return self }
        return BrowserSearchResult(
            title: title,
            url: url,
            browserName: browserName,
            type: type,
            timestamp: value,
            windowIndex: windowIndex,
            tabIndex: tabIndex,
            windowName: windowName,
            bookmarkID: bookmarkID,
            profileName: profileName,
            folderPath: folderPath,
            isCurrentFlowActiveTab: isCurrentFlowActiveTab,
            hasMediaIndicator: hasMediaIndicator,
            tabID: tabID,
            isAudible: isAudible,
            isMuted: isMuted,
            isPinned: isPinned,
            isDiscarded: isDiscarded,
            tabGroupTitle: tabGroupTitle,
            isPinnedAudibleTab: isPinnedAudibleTab,
            isGhost: isGhost
        )
    }

    var id: String {
        switch type {
        case .sent:
            return [browserName, type.rawValue, bookmarkID ?? url, String(timestamp.timeIntervalSince1970)].joined(separator: "|")
        case .tab:
            if isGhost {
                return [browserName, profileName ?? "", type.rawValue, "ghost", url].joined(separator: "|")
            }
            if let tabID {
                return [browserName, type.rawValue, "id", String(tabID), url].joined(separator: "|")
            }
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
        case .sent, .tab, .history:
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

        if type == .tab,
           let tabGroupTitle,
           !tabGroupTitle.isEmpty {
            metadata.append(tabGroupTitle)
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

    /// Every word of `query` must appear in the title or the URL, in any order,
    /// ignoring case, accents and punctuation. See `SearchMatching.swift`.
    ///
    /// Folds `query` on every call — fine for a one-off check, but filtering
    /// many candidates against the same typed query should fold it once via
    /// `searchWords(in:)` and call `matches(words:)` instead.
    func matches(query: String) -> Bool {
        matches(words: searchWords(in: query))
    }

    /// Same as `matches(query:)`, but takes an already-folded word list (see
    /// `searchWords(in:)`) so filtering many candidates against one typed
    /// query doesn't re-fold that query for every candidate.
    func matches(words: [String]) -> Bool {
        foldedKeys([normalizedTitleKey, normalizedURLKey], containAllWordsOf: words)
    }

    /// Short relative-time label ("2m", "3h", "Yest", "3d", "Mar 14") for the
    /// last-visit (history) or last-active (tab) timestamp. Returns nil when
    /// the timestamp is unset (epoch ~0) or the type doesn't carry a meaningful
    /// recency signal (bookmarks).
    var relativeRecencyLabel: String? {
        switch type {
        case .bookmark:
            return nil
        case .sent, .tab, .history:
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

    var tabURLRecencyKey: String? {
        guard type == .tab else { return nil }
        return makeTabURLRecencyKey(browserName: browserName, url: url)
    }

    /// Last non-empty path segment of `url` (e.g. "https://notion.so/roadmap"
    /// -> "roadmap"), for the short inline label shown next to the title in
    /// Minimal row style when there's room for it. Nil when the URL has no
    /// path to show (bare domain) or its last segment just repeats the title.
    var urlPathSlug: String? {
        guard let parsed = URL(string: url) else { return nil }
        guard let slug = parsed.pathComponents.last(where: { $0 != "/" }), !slug.isEmpty else { return nil }
        return slug == title ? nil : slug
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

func makeTabURLRecencyKey(browserName: String, url: String) -> String {
    [browserName, url].joined(separator: "|")
}

/// Applies the sticky-audible grace window on top of each tab's raw
/// (this-instant) `isPinnedAudibleTab` value: once a tab is heard, it stays
/// flagged for `graceWindow` seconds past the last time it was heard, so a
/// live call or a music/video tab doesn't flicker in and out of the pinned
/// position during quiet moments. `lastAudibleSeenAt` is caller-owned, keyed
/// by `tabRecencyKey`, and persists across calls (see `BrowserTabService`).
func annotatingPinnedAudibleTabs(
    _ tabs: [BrowserSearchResult],
    lastAudibleSeenAt: inout [String: Date],
    now: Date,
    graceWindow: TimeInterval = 15
) -> [BrowserSearchResult] {
    tabs.map { tab in
        guard let key = tab.tabRecencyKey else { return tab }

        if tab.isPinnedAudibleTab {
            lastAudibleSeenAt[key] = now
            return tab
        }

        guard let seenAt = lastAudibleSeenAt[key],
              now.timeIntervalSince(seenAt) <= graceWindow else {
            return tab
        }
        return tab.settingPinnedAudible(true)
    }
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

    var pinnedTabs: [BrowserSearchResult] = []
    var sent: [BrowserSearchResult] = []
    var unpinnedTabs: [BrowserSearchResult] = []
    var bookmarks: [BrowserSearchResult] = []
    var history: [BrowserSearchResult] = []
    sent.reserveCapacity(results.count)
    pinnedTabs.reserveCapacity(results.count)
    unpinnedTabs.reserveCapacity(results.count)
    for r in results {
        switch r.type {
        case .sent: sent.append(r)
        case .tab:
            if r.isPinned {
                pinnedTabs.append(r)
            } else {
                unpinnedTabs.append(r)
            }
        case .bookmark: bookmarks.append(r)
        case .history: history.append(r)
        }
    }

    let sortedPinnedTabs = sortTabsTier(pinnedTabs, frecencyScore: frecencyScore)
    let sortedSent = sortByTimestampTier(sent)
    let sortedUnpinnedTabs = sortTabsTier(unpinnedTabs, frecencyScore: frecencyScore)
    let sortedBookmarks = sortByTimestampTier(bookmarks)
    let sortedHistory = sortByTimestampTier(history)

    // Concatenate in priority order — pinned tabs (top priority!) < sent(-1) < unpinned tabs(0) < bookmark(1) < history(2).
    var out: [BrowserSearchResult] = []
    out.reserveCapacity(sortedPinnedTabs.count + sortedSent.count + sortedUnpinnedTabs.count + sortedBookmarks.count + sortedHistory.count)
    out.append(contentsOf: sortedPinnedTabs)
    out.append(contentsOf: sortedSent)
    out.append(contentsOf: sortedUnpinnedTabs)
    out.append(contentsOf: sortedBookmarks)
    out.append(contentsOf: sortedHistory)
    return out
}

/// Sort the tabs tier. When `frecencyScore` is provided, precomputes the
/// score for each tab once and sorts the decorated array. Tabs with equal
/// scores fall through to timestamp / browserName / title for a stable feel.
/// Pinned tabs (`isPinned`) always have top priority, followed by audible
/// tabs (`isPinnedAudibleTab`) ahead of the rest of the tier regardless of
/// frecency.
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
        if lhs.result.isPinned != rhs.result.isPinned {
            return lhs.result.isPinned
        }
        if lhs.result.isGhost != rhs.result.isGhost {
            return !lhs.result.isGhost
        }
        if lhs.result.isPinnedAudibleTab != rhs.result.isPinnedAudibleTab {
            return lhs.result.isPinnedAudibleTab
        }
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
/// browserName asc, title asc. Bookmarks/history never set
/// `isPinned` or `isPinnedAudibleTab`, so the pin check is a no-op for them —
/// but this is also the quick-open (empty-query) path's sort for tabs, which
/// never gets a frecency score, so it needs the same pin-to-top checks
/// `sortTabsTier`'s frecency branch has.
private func sortByTimestampTier(_ items: [BrowserSearchResult]) -> [BrowserSearchResult] {
    if items.count <= 1 { return items }
    return items.sorted { lhs, rhs in
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }
        if lhs.isGhost != rhs.isGhost {
            return !lhs.isGhost
        }
        if lhs.isPinnedAudibleTab != rhs.isPinnedAudibleTab {
            return lhs.isPinnedAudibleTab
        }
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        if lhs.browserName != rhs.browserName {
            return lhs.browserName.localizedCompare(rhs.browserName) == .orderedAscending
        }
        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }
}

/// Key identifying "the same page" for cross-type duplicate collapsing: same
/// browser and profile (a page open in a work profile is worth surfacing
/// separately from the personal-profile copy), same coarse page identity
/// (host + path, ignoring query/fragment — see `historyPageIdentity`), and
/// the same title once a live count badge (`"(2) "`) is stripped. Title stays
/// part of the key on purpose, mirroring `HistorySearchExpansion.canonicalHistoryKey`:
/// it's the guard that keeps genuinely different pages (e.g. two distinct
/// search-result pages sharing a path) from collapsing into one.
func duplicatePageDedupeKey(for result: BrowserSearchResult) -> String {
    result.duplicateDedupeKey
}

/// Collapses duplicate pages across tabs, bookmarks, and history in one pass —
/// the mixed, unscoped search list otherwise shows the same page once per
/// result type plus once per stale history row (e.g. a pinned Notion tab
/// re-indexed into history at several different unread-count badges).
///
/// Within a duplicate group, a live tab always wins: switching to an
/// already-open tab is a cheaper, different action than reopening the page
/// from a bookmark or history row, so it should surface even if a history
/// row happens to have a newer timestamp. Among non-tab duplicates, the
/// higher-frecency result wins; frecency is only recorded for pages opened
/// through this app, so most groups will have no score on either side and
/// fall through to the most recent timestamp.
func deduplicatingSamePages(
    _ results: [BrowserSearchResult],
    frecencyScore: (BrowserSearchResult) -> Double
) -> [BrowserSearchResult] {
    guard results.count > 1 else { return results }

    var winners: [String: BrowserSearchResult] = [:]
    winners.reserveCapacity(results.count)

    for candidate in results {
        let key = duplicatePageDedupeKey(for: candidate)
        guard let current = winners[key] else {
            winners[key] = candidate
            continue
        }
        if isPreferredDuplicate(candidate, over: current, frecencyScore: frecencyScore) {
            winners[key] = candidate
        }
    }

    return Array(winners.values)
}

private func isPreferredDuplicate(
    _ candidate: BrowserSearchResult,
    over current: BrowserSearchResult,
    frecencyScore: (BrowserSearchResult) -> Double
) -> Bool {
    if candidate.isPinned != current.isPinned {
        return candidate.isPinned
    }

    if candidate.isGhost != current.isGhost {
        return !candidate.isGhost
    }

    if candidate.type != current.type {
        return candidate.type.sortPriority < current.type.sortPriority
    }

    let candidateScore = frecencyScore(candidate)
    let currentScore = frecencyScore(current)
    if candidateScore != currentScore {
        return candidateScore > currentScore
    }

    return candidate.timestamp > current.timestamp
}

func quickOpenVisibleTabs(from results: [BrowserSearchResult], limit: Int) -> [BrowserSearchResult] {
    Array(results.prefix(max(0, limit)))
}

/// Sorts tabs strictly by raw recency for Quick Open / Recents view (⌘1 / empty query).
/// Empty query (quick-open) must rank by raw recency so the tab you *just* used
/// is always at the top — a hard UX guarantee that frecency or tab pinning
/// must not violate.
func sortQuickOpenTabs(_ tabs: [BrowserSearchResult]) -> [BrowserSearchResult] {
    if tabs.count <= 1 { return tabs }
    return tabs.sorted { lhs, rhs in
        if lhs.isGhost != rhs.isGhost {
            return !lhs.isGhost
        }
        if lhs.isPinnedAudibleTab != rhs.isPinnedAudibleTab {
            return lhs.isPinnedAudibleTab
        }
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp > rhs.timestamp
        }
        if lhs.browserName != rhs.browserName {
            return lhs.browserName.localizedCompare(rhs.browserName) == .orderedAscending
        }
        return lhs.title.localizedCompare(rhs.title) == .orderedAscending
    }
}

/// Orders items for Quick Open / Recents: live tabs by raw recency, then
/// bookmarks, then history. iPhone-sent links (`.sent`) are deliberately left
/// out — they live in the Stack view, so an unopened backlog can never push
/// the tab you were just using out of the short Recents list.
func sortQuickOpenResults(_ items: [BrowserSearchResult]) -> [BrowserSearchResult] {
    if items.count <= 1 { return items.filter { $0.type != .sent } }
    var tabs: [BrowserSearchResult] = []
    var bookmarks: [BrowserSearchResult] = []
    var history: [BrowserSearchResult] = []
    for item in items {
        switch item.type {
        case .sent: continue
        case .tab: tabs.append(item)
        case .bookmark: bookmarks.append(item)
        case .history: history.append(item)
        }
    }
    return sortQuickOpenTabs(tabs)
        + bookmarks.sorted { $0.timestamp > $1.timestamp }
        + history.sorted { $0.timestamp > $1.timestamp }
}

func allQuickOpenTabs(from results: [BrowserSearchResult]) -> [BrowserSearchResult] {
    sortQuickOpenTabs(results)
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
