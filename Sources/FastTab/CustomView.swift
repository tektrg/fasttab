import Foundation
import IndieSearch

/// A user-defined, swipeable page in the command bar (after Recent and Stack):
/// a saved set of filters over open tabs, bookmarks and history, plus how to
/// group what matches.
///
/// Filter semantics (owner decision 2026-11-06): **AND across fields, OR
/// within a field** — e.g. `domains: ["github.com", "gitlab.com"]` with
/// `types: [.tab]` means "open tabs on GitHub *or* GitLab". An empty field
/// constrains nothing. Evaluation lives in `CustomViewFilter`; grouping in
/// `CustomViewGrouping`.
///
/// Persisted as JSON (`CustomViewStore`). Decoding tolerates missing and
/// unknown keys/values so the schema can grow (and later sync to iPhone)
/// without wiping a user's saved views.
struct CustomView: Codable, Identifiable, Equatable, Hashable, Sendable {
    static let defaultIconName = "square.stack.3d.up"
    /// The only result kinds a custom view can show. Sent links and FastTab
    /// List items have their own surfaces.
    static let allowedTypes: Set<BrowserResultType> = [.tab, .bookmark, .history]

    var id: UUID
    var name: String
    /// SF Symbol name shown on the page indicator / builder.
    var iconName: String
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
    /// Free text; every word must appear in the title or URL (same folding as
    /// the command bar search). Empty = no constraint.
    var keywords: String
    var lastVisited: LastVisitedRule
    /// Browser-pinned tab flag (`BrowserSearchResult.isPinned`). `.only`
    /// admits pinned tabs alone (bookmarks/history are never pinned);
    /// `.exclude` drops pinned tabs. `.any` when absent from older JSON.
    var pinned: PinnedRule
    /// Natural-language "AI filter" (Foundation Models). Empty = off. Stored
    /// only — `CustomViewFilter` does not evaluate it.
    var semanticPrompt: String
    var groupBy: CustomViewGroupBy

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String = CustomView.defaultIconName,
        types: Set<BrowserResultType> = [],
        profiles: [String] = [],
        domains: [String] = [],
        keywords: String = "",
        lastVisited: LastVisitedRule = .any,
        pinned: PinnedRule = .any,
        semanticPrompt: String = "",
        groupBy: CustomViewGroupBy = .none
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.types = types.intersection(Self.allowedTypes)
        self.profiles = profiles
        self.domains = domains
        self.keywords = keywords
        self.lastVisited = lastVisited
        self.pinned = pinned
        self.semanticPrompt = semanticPrompt
        self.groupBy = groupBy
    }

    /// The types this view actually admits (`types`, or all allowed when empty).
    var effectiveTypes: Set<BrowserResultType> {
        types.isEmpty ? Self.allowedTypes : types
    }

    var hasSemanticFilter: Bool {
        !semanticPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, iconName, types, profiles, domains, keywords, lastVisited, pinned, semanticPrompt, groupBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown type strings (a kind added by a newer build) are skipped,
        // not fatal.
        let rawTypes = (try? c.decodeIfPresent([String].self, forKey: .types)) ?? nil
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "",
            iconName: (try? c.decodeIfPresent(String.self, forKey: .iconName)) ?? Self.defaultIconName,
            types: Set((rawTypes ?? []).compactMap(BrowserResultType.init(rawValue:))),
            profiles: (try? c.decodeIfPresent([String].self, forKey: .profiles)) ?? [],
            domains: (try? c.decodeIfPresent([String].self, forKey: .domains)) ?? [],
            keywords: (try? c.decodeIfPresent(String.self, forKey: .keywords)) ?? "",
            lastVisited: (try? c.decodeIfPresent(LastVisitedRule.self, forKey: .lastVisited)) ?? .any,
            pinned: (try? c.decodeIfPresent(PinnedRule.self, forKey: .pinned)) ?? .any,
            semanticPrompt: (try? c.decodeIfPresent(String.self, forKey: .semanticPrompt)) ?? "",
            groupBy: (try? c.decodeIfPresent(CustomViewGroupBy.self, forKey: .groupBy)) ?? .none
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(iconName, forKey: .iconName)
        // Sorted so the stored JSON is deterministic (diffable, sync-friendly).
        try c.encode(types.map(\.rawValue).sorted(), forKey: .types)
        try c.encode(profiles, forKey: .profiles)
        try c.encode(domains, forKey: .domains)
        try c.encode(keywords, forKey: .keywords)
        try c.encode(lastVisited, forKey: .lastVisited)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(semanticPrompt, forKey: .semanticPrompt)
        try c.encode(groupBy, forKey: .groupBy)
    }
}

// MARK: - Last visited

/// Time filter on an item's last visit (see `CustomViewFilter.lastVisit`).
/// Items whose last visit is unknown match **neither** `.within` nor
/// `.olderThan` — only `.any`.
enum LastVisitedRule: Codable, Hashable, Sendable {
    case any
    /// Visited no more than `seconds` ago.
    case within(TimeInterval)
    /// Last visited more than `seconds` ago.
    case olderThan(TimeInterval)

    /// Durations offered by the builder, in display order.
    static let presets: [LastVisitedPreset] = [
        LastVisitedPreset(seconds: 3_600, displayName: "1 hour"),
        LastVisitedPreset(seconds: 86_400, displayName: "24 hours"),
        LastVisitedPreset(seconds: 7 * 86_400, displayName: "7 days"),
        LastVisitedPreset(seconds: 30 * 86_400, displayName: "30 days"),
        LastVisitedPreset(seconds: 90 * 86_400, displayName: "90 days"),
    ]

    var seconds: TimeInterval? {
        switch self {
        case .any: return nil
        case .within(let s), .olderThan(let s): return s
        }
    }

    /// "Any time", "Within 7 days", "Older than 30 days".
    var displayName: String {
        switch self {
        case .any: return "Any time"
        case .within(let s): return "Within \(Self.durationName(s))"
        case .olderThan(let s): return "Older than \(Self.durationName(s))"
        }
    }

    static func durationName(_ seconds: TimeInterval) -> String {
        if let preset = presets.first(where: { $0.seconds == seconds }) { return preset.displayName }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: seconds) ?? "\(Int(seconds))s"
    }

    // Stored as `{"kind": "within", "seconds": 604800}` — stable and readable,
    // unlike the synthesized `{"within": {"_0": …}}` shape.
    private enum CodingKeys: String, CodingKey { case kind, seconds }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "any"
        let seconds = (try? c.decodeIfPresent(TimeInterval.self, forKey: .seconds)) ?? nil
        switch (kind, seconds) {
        case ("within", let s?) where s > 0: self = .within(s)
        case ("olderThan", let s?) where s > 0: self = .olderThan(s)
        default: self = .any
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .any:
            try c.encode("any", forKey: .kind)
        case .within(let s):
            try c.encode("within", forKey: .kind)
            try c.encode(s, forKey: .seconds)
        case .olderThan(let s):
            try c.encode("olderThan", forKey: .kind)
            try c.encode(s, forKey: .seconds)
        }
    }
}

struct LastVisitedPreset: Hashable, Identifiable, Sendable {
    let seconds: TimeInterval
    let displayName: String
    var id: TimeInterval { seconds }
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

enum CustomViewGroupBy: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case lastVisited
    case domain

    var displayName: String {
        switch self {
        case .none: return "None"
        case .lastVisited: return "Last visited"
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
