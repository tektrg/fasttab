import Foundation
import IndieSavedViews
import IndieSearch

/// A user-defined, swipeable page in the command bar (after Recent and Stack):
/// a saved set of filters over open tabs, bookmarks and history, plus how to
/// group what matches. The shared `SavedView` holds id, name, icon, keywords,
/// AI prompt and group-by; `WebViewCriteria` holds Fast Tab's own filters
/// (read and written directly, e.g. `view.domains`).
///
/// Filter semantics (owner decision 2026-11-06): **AND across fields, OR
/// within a field** — e.g. `domains: ["github.com", "gitlab.com"]` with
/// `types: [.tab]` means "open tabs on GitHub *or* GitLab". An empty field
/// constrains nothing. Evaluation lives in `CustomViewFilter`; grouping in
/// `CustomViewGrouping`.
///
/// Persisted as one flat JSON object per view (`CustomViewStore`, key
/// `FastTab.customViews.v1`); the format predates the shared model and must
/// not change. Decoding tolerates missing and unknown keys/values.
typealias CustomView = SavedView<WebViewCriteria>

/// Fast Tab's custom-view filters over open tabs, bookmarks and history.
struct WebViewCriteria: SavedViewCriteria {
    typealias GroupBy = CustomViewGroupBy
    static let defaultIconName = "square.stack.3d.up"
    /// The only result kinds a custom view can show. Sent links and FastTab
    /// List items have their own surfaces.
    static let allowedTypes: Set<BrowserResultType> = [.tab, .bookmark, .history]

    /// Subset of `allowedTypes`; empty = all three. Anything outside
    /// `allowedTypes` is dropped on assignment and on decode.
    var types: Set<BrowserResultType> {
        didSet { types = types.intersection(Self.allowedTypes) }
    }
    /// Browser profile names (case-insensitive exact match on
    /// `BrowserSearchResult.profileName`); empty = any profile.
    var profiles: [String]
    /// Domains as the user typed them; normalized at evaluation time with
    /// `CustomViewDomain.normalize` (so "https://www.GitHub.com/x" and
    /// "*.github.com" both mean `github.com` + its subdomains). Empty = any.
    var domains: [String]
    /// Browser-pinned tab flag (`BrowserSearchResult.isPinned`). `.only`
    /// admits pinned tabs alone (bookmarks/history are never pinned);
    /// `.exclude` drops pinned tabs. `.any` when absent from older JSON.
    var pinned: PinnedRule

    init() { self.init(types: []) }

    init(
        types: Set<BrowserResultType> = [],
        profiles: [String] = [],
        domains: [String] = [],
        pinned: PinnedRule = .any
    ) {
        self.types = types.intersection(Self.allowedTypes)
        self.profiles = profiles
        self.domains = domains
        self.pinned = pinned
    }

    // "Last visited" (a `{"kind","seconds"}` time filter under `lastVisited`) was removed
    // 2026-11-12: last-visit data was inaccurate (Chromium tabs report no real time,
    // bookmarks borrow history visits, the history cache is shallow). Old JSON still
    // decodes — the key is ignored — and is no longer written, so an older build reads
    // a re-saved view as "Any time".
    private enum CodingKeys: String, CodingKey {
        case types, profiles, domains, pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown type strings (a kind added by a newer build) are skipped,
        // not fatal.
        let rawTypes = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? nil
        self.init(
            types: Set((rawTypes ?? []).compactMap(BrowserResultType.init(rawValue:))),
            profiles: (try? c.decodeIfPresent([String].self, forKey: .profiles)) ?? [],
            domains: (try? c.decodeIfPresent([String].self, forKey: .domains)) ?? [],
            pinned: (try? c.decodeIfPresent(PinnedRule.self, forKey: .pinned)) ?? .any
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Sorted so the stored JSON is deterministic (diffable, sync-friendly).
        try c.encode(types.map(\.rawValue).sorted(), forKey: .types)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(domains, forKey: .domains)
        try c.encode(pinned, forKey: .pinned)
    }
}

extension SavedView where Criteria == WebViewCriteria {
    static var defaultIconName: String { WebViewCriteria.defaultIconName }
    static var allowedTypes: Set<BrowserResultType> { WebViewCriteria.allowedTypes }

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String = WebViewCriteria.defaultIconName,
        types: Set<BrowserResultType> = [],
        profiles: [String] = [],
        domains: [String] = [],
        keywords: String = "",
        pinned: PinnedRule = .any,
        semanticPrompt: String = "",
        groupBy: CustomViewGroupBy = .none
    ) {
        self.init(
            id: id, name: name, iconName: iconName, keywords: keywords,
            semanticPrompt: semanticPrompt, groupBy: groupBy,
            criteria: WebViewCriteria(types: types, profiles: profiles, domains: domains, pinned: pinned)
        )
    }

    /// The types this view actually admits (`types`, or all allowed when empty).
    var effectiveTypes: Set<BrowserResultType> {
        self.types.isEmpty ? Self.allowedTypes : self.types
    }
}

// MARK: - Pinned

/// Filter on a tab's pinned flag (`BrowserSearchResult.isPinned`): the
/// browser's pin (companion extension) OR FastTab's own pin, which the live-tab
/// cache overlays for every browser (`MyOrderStore.overlayPinStatus`).
enum PinnedRule: String, Codable, CaseIterable, Hashable, Sendable {
    case any
    /// Pinned tabs only (so no bookmarks or history).
    case only
    /// Everything except pinned tabs.
    case exclude

    /// Segmented-control label.
    var displayName: String {
        switch self {
        case .any: return "Any"
        case .only: return "Pinned"
        case .exclude: return "Not pinned"
        }
    }

    func matches(_ item: BrowserSearchResult) -> Bool {
        switch self {
        case .any: return true
        case .only: return item.isPinned
        case .exclude: return !item.isPinned
        }
    }

    /// Unknown values (a rule added by a newer build) fall back to `.any`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PinnedRule(rawValue: raw) ?? .any
    }
}

// MARK: - Group by

enum CustomViewGroupBy: String, SavedViewGroupBy, CaseIterable {
    static var defaultValue: CustomViewGroupBy { .none }

    case none
    // `lastVisited` (day buckets) was removed 2026-11-12 with the "Last visited"
    // filter; stored "lastVisited" decodes to `.none` via the fallback below.
    case domain

    var displayName: String {
        switch self {
        case .none: return "None"
        case .domain: return "Domain"
        }
    }

    /// Unknown values (a mode added by a newer build) fall back to `.none`.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CustomViewGroupBy(rawValue: raw) ?? .none
    }
}

// MARK: - Domain normalization

enum CustomViewDomain {
    /// A `*wildcard*` or `/regex/` host pattern (shared `TextPattern`), matched against the bare host.
    /// A leading `*.` alone is not a pattern: `*.github.com` still means github.com + subdomains.
    static func isPattern(_ raw: String) -> Bool {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if TextPattern.isRegex(String(s)) { return true }
        while s.hasPrefix("*.") { s = s.dropFirst(2) }
        return TextPattern.isWildcard(String(s))
    }

    /// Bare lowercase host from whatever the user typed: strips scheme, path,
    /// query, port, credentials, leading `*.` / `.` and `www.`.
    /// "https://www.GitHub.com/x" → "github.com", "*.google.com" →
    /// "google.com". Nil when nothing host-like is left.
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let end = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<end]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.hasPrefix("[") {
            // IPv6 literal: keep through the closing bracket, drop any port.
            if let close = s.firstIndex(of: "]") { s = String(s[...close]) }
        } else if let colon = s.firstIndex(of: ":") {
            s = String(s[..<colon])
        }
        while s.hasPrefix("*") || s.hasPrefix(".") { s.removeFirst() }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix(".") { s.removeLast() }
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return nil }
        return s
    }

    /// Lowercased host of a result URL with a leading `www.` removed; nil for
    /// non-web URLs (Finder paths, `about:` pages).
    static func host(ofURL url: String) -> String? {
        guard let host = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
              !host.isEmpty else { return nil }
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h.isEmpty ? nil : h
    }

    /// True when `host` equals `domain` or is a subdomain of it.
    static func host(_ host: String, isWithin domain: String) -> Bool {
        host == domain || (host.count > domain.count && host.hasSuffix("." + domain))
    }
}
