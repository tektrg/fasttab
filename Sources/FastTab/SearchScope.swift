import Foundation

// MARK: - Model

enum HistoryTimeScope: String, CaseIterable, Equatable, Hashable, Sendable {
    case today
    case yesterday
    case lastWeek
    case lastMonth

    var label: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .lastWeek: return "last week"
        case .lastMonth: return "last month"
        }
    }

    /// Inclusive lower bound of the range, computed against `Calendar.current`.
    func startDate(now: Date = Date()) -> Date {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        switch self {
        case .today:
            return startOfToday
        case .yesterday:
            return cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        case .lastWeek:
            return cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        case .lastMonth:
            return cal.date(byAdding: .month, value: -1, to: startOfToday) ?? startOfToday
        }
    }

    /// Exclusive upper bound (only meaningful for `.yesterday`, which is a single-day window).
    func endDate(now: Date = Date()) -> Date? {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        switch self {
        case .yesterday: return startOfToday
        default: return nil
        }
    }
}

struct BookmarkFolderRef: Equatable, Hashable, Sendable {
    let browserName: String
    let profileName: String?
    let folderPath: String

    var id: String {
        [browserName, profileName ?? "", folderPath].joined(separator: "|")
    }

    var displayName: String {
        let leaf = folderPath.split(separator: "/").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return leaf?.isEmpty == false ? leaf! : folderPath
    }
}

struct WindowRef: Equatable, Hashable, Sendable {
    let browserName: String
    let windowName: String
    let windowIndex: Int

    var id: String { [browserName, windowName, String(windowIndex)].joined(separator: "|") }
    var displayName: String { windowName.isEmpty ? "Window \(windowIndex)" : windowName }
}

struct ScopeChip: Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case duplicate
        case bookmarks
        case bookmarksFolder(BookmarkFolderRef)
        /// `nil` time scope means "all history" — the parent scope without a
        /// time bound (produced by typing text that matches no time preset).
        case history(HistoryTimeScope?)
        case window(WindowRef)
        /// Pin results to a specific source app (e.g. "Finder"). Acts as an
        /// AND constraint on `browserName`. Today only non-browser sources
        /// appear in the dropdown — browser-vs-browser filtering is left to
        /// `@Window:` since browser tabs already mix freely.
        case source(String)
    }

    let id = UUID()
    let kind: Kind

    var displayLabel: String {
        switch kind {
        case .duplicate: return "Duplicate"
        case .bookmarks: return "Bookmarks"
        case .bookmarksFolder(let ref): return "Bookmarks: \(ref.displayName)"
        case .history(let time?): return "History: \(time.label)"
        case .history(nil): return "History"
        case .window(let ref): return "Window: \(ref.displayName)"
        case .source(let name): return name
        }
    }

    static func == (lhs: ScopeChip, rhs: ScopeChip) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }
}

// MARK: - Parser

/// State of the in-input scope-suggestion menu.
enum ScopeSuggestionMode: Equatable {
    /// No active `@` token; dropdown hidden.
    case hidden
    /// Showing the root menu (`@` typed at token start). `prefix` is the
    /// substring after `@` used to filter options.
    case root(prefix: String, tokenRange: Range<String.Index>)
    /// Drilling into `@Bookmarks:` — `prefix` is text after the trailing colon.
    case bookmarks(prefix: String, tokenRange: Range<String.Index>)
    /// Drilling into `@History:` — `prefix` is text after the trailing colon.
    case history(prefix: String, tokenRange: Range<String.Index>)
}

enum ScopeSuggestionParser {
    /// Examines the current search input and returns the dropdown mode.
    /// Only fires when `@` (or `@Bookmarks:` / `@History:`) appears as a
    /// fresh token at the start of input or after whitespace.
    static func mode(for text: String) -> ScopeSuggestionMode {
        // Find the last token (after the last whitespace).
        let tokenStart: String.Index
        if let lastSpace = text.lastIndex(where: { $0.isWhitespace }) {
            tokenStart = text.index(after: lastSpace)
        } else {
            tokenStart = text.startIndex
        }
        let token = text[tokenStart...]
        let lower = token.lowercased()

        if lower.hasPrefix("@bookmarks:") {
            let dropCount = "@bookmarks:".count
            let prefix = String(token.dropFirst(dropCount))
            return .bookmarks(prefix: prefix, tokenRange: tokenStart..<text.endIndex)
        }
        if lower.hasPrefix("@history:") {
            let dropCount = "@history:".count
            let prefix = String(token.dropFirst(dropCount))
            return .history(prefix: prefix, tokenRange: tokenStart..<text.endIndex)
        }
        if lower.hasPrefix("@") {
            let prefix = String(token.dropFirst(1))
            return .root(prefix: prefix, tokenRange: tokenStart..<text.endIndex)
        }
        return .hidden
    }
}

// MARK: - Suggestions

enum RootSuggestion: Equatable, Hashable {
    case duplicate
    case bookmarks
    case history
    case window(WindowRef)
    /// Non-browser source filter (e.g. Finder). Picking commits a
    /// `Kind.source(name)` chip that pins `browserName` to the source app.
    case source(name: String)

    var label: String {
        switch self {
        case .duplicate: return "Duplicate"
        case .bookmarks: return "Bookmarks"
        case .history: return "History"
        case .window(let ref): return ref.displayName
        case .source(let name): return name
        }
    }

    var detail: String? {
        switch self {
        case .duplicate: return "Tabs with duplicate URLs"
        case .bookmarks: return "Search bookmarks"
        case .history: return "Search history"
        case .window: return "Tabs in this window"
        case .source(let name): return "Only \(name) results"
        }
    }

    var symbol: String {
        switch self {
        case .duplicate: return "square.on.square"
        case .bookmarks: return "bookmark"
        case .history: return "clock.arrow.circlepath"
        case .window: return "macwindow"
        case .source(let name):
            // Finder gets its system glyph; other future sources fall back to
            // a generic app icon. Kept in sync with the actual app the chip
            // pins so the dropdown row reads naturally.
            if name == "Finder" { return "folder" }
            return "app"
        }
    }
}

enum ScopeSuggestion: Equatable, Hashable {
    case root(RootSuggestion)
    case bookmarkFolder(BookmarkFolderRef)
    case historyTime(HistoryTimeScope)

    var label: String {
        switch self {
        case .root(let r): return r.label
        case .bookmarkFolder(let ref): return ref.displayName
        case .historyTime(let t): return t.label
        }
    }

    var detail: String? {
        switch self {
        case .root(let r): return r.detail
        case .bookmarkFolder(let ref): return ref.folderPath
        case .historyTime: return nil
        }
    }

    var symbol: String {
        switch self {
        case .root(let r): return r.symbol
        case .bookmarkFolder: return "folder"
        case .historyTime: return "clock"
        }
    }
}

// MARK: - Filter pipeline

/// Strict-AND filter set built from a chip list. Each non-nil property is a
/// constraint a candidate result must satisfy. Disjoint combinations (e.g.
/// `requireType == .bookmark` AND `requireWindow` set) intentionally yield
/// empty results.
struct ScopeFilter: Equatable {
    /// If set, only results of this type pass.
    var requiredType: BrowserResultType?
    /// If set, bookmarks must live under (or inside) this folder.
    var bookmarkFolder: BookmarkFolderRef?
    /// If set, history results must be on/after this date.
    var historySince: Date?
    /// If set, history results must be before this date.
    var historyBefore: Date?
    /// If set, tabs must be in this window (id-matched).
    var window: WindowRef?
    /// If true, only tabs whose exact URL appears 2+ times in the live-tabs list.
    var duplicateOnly: Bool = false
    /// If set, only results whose `browserName` matches this source app pass.
    /// Drives the fetch-path short-circuit in `BrowserTabService` (no point
    /// polling Chrome when we've pinned to Finder).
    var source: String?

    /// True when nothing is constrained — fast path can skip the filter.
    var isPassthrough: Bool {
        requiredType == nil && bookmarkFolder == nil && historySince == nil
            && historyBefore == nil && window == nil && !duplicateOnly && source == nil
    }

    /// Set internally when chip stack contains incompatible source-types.
    fileprivate var conflicted: Bool = false

    static func from(chips: [ScopeChip]) -> ScopeFilter {
        var filter = ScopeFilter()
        var seenTypes: Set<BrowserResultType> = []

        func require(type: BrowserResultType) {
            seenTypes.insert(type)
            filter.requiredType = type
        }

        for chip in chips {
            switch chip.kind {
            case .duplicate:
                require(type: .tab)
                filter.duplicateOnly = true
            case .bookmarks:
                require(type: .bookmark)
            case .bookmarksFolder(let ref):
                require(type: .bookmark)
                filter.bookmarkFolder = ref
            case .history(let time):
                require(type: .history)
                if let time {
                    filter.historySince = time.startDate()
                    filter.historyBefore = time.endDate()
                }
            case .window(let ref):
                require(type: .tab)
                filter.window = ref
            case .source(let name):
                // Two source chips with different names → unsatisfiable.
                if let existing = filter.source, existing != name {
                    filter.conflicted = true
                }
                filter.source = name
            }
        }

        if seenTypes.count > 1 {
            filter.conflicted = true
        }
        // Source vs window: pinning a window in a different browser than the
        // pinned source can never resolve.
        if let source = filter.source, let window = filter.window,
           window.browserName != source {
            filter.conflicted = true
        }
        return filter
    }

    /// False when the chip stack contains incompatible source-type constraints
    /// (e.g. `in:Bookmarks` AND `in:History`). Callers should short-circuit to
    /// an empty result list under strict-AND semantics.
    var isSatisfiable: Bool { !conflicted }

    func matches(_ result: BrowserSearchResult) -> Bool {
        if let requiredType, result.type != requiredType { return false }
        if let bookmarkFolder {
            guard result.type == .bookmark,
                  result.browserName == bookmarkFolder.browserName,
                  (result.profileName ?? "") == (bookmarkFolder.profileName ?? ""),
                  let path = result.folderPath,
                  (path == bookmarkFolder.folderPath
                    || path.hasPrefix(bookmarkFolder.folderPath + " / "))
            else { return false }
        }
        if let historySince, result.type == .history, result.timestamp < historySince { return false }
        if let historyBefore, result.type == .history, result.timestamp >= historyBefore { return false }
        if let window {
            // Match on full WindowRef id so two windows with the same name
            // (or unnamed windows that all collapse to "") stay distinct.
            guard result.type == .tab,
                  result.browserName == window.browserName,
                  (result.windowName ?? "") == window.windowName,
                  (result.windowIndex ?? 0) == window.windowIndex
            else { return false }
        }
        if let source, result.browserName != source { return false }
        return true
    }
}
