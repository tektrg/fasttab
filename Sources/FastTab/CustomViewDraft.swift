import Foundation
import IndieSearch

/// The view builder's working copy of a `CustomView` (bar inline editor and
/// Settings › Views sheet share it). Differs from the saved model where the
/// form needs to: `types` is explicit (empty = nothing ticked, which is
/// invalid — in the model empty means "all"), and domains are the raw text
/// the user is typing so invalid entries can be shown before they're dropped.
struct CustomViewDraft: Equatable {
    var id: UUID
    var name: String
    var iconName: String
    var types: Set<BrowserResultType>
    var profiles: [String]
    /// Comma / space / newline separated, as typed.
    var domainsText: String
    var keywords: String
    var lastVisited: LastVisitedRule
    var pinned: PinnedRule
    var semanticPrompt: String
    var groupBy: CustomViewGroupBy

    /// Curated picker icons (all present in SF Symbols 5 / macOS 14).
    static let iconChoices: [String] = [
        CustomView.defaultIconName, "star", "briefcase", "book",
        "newspaper", "graduationcap", "hammer", "chevron.left.forwardslash.chevron.right",
        "cart", "film", "music.note", "gamecontroller",
        "person.2", "globe", "flag", "bolt",
    ]

    /// Display order of the type toggles.
    static let typeOrder: [BrowserResultType] = [.tab, .bookmark, .history]

    // MARK: Last visited hint

    /// How many whole days back "Last visited" can see. FastTab only caches
    /// the newest history rows per browser profile (`historyCachePerBrowserLimit`),
    /// so older visits are unknown. Per browser + profile with history: now −
    /// its oldest cached row; the shortest reach wins. Rounded down, min 1.
    /// Nil when no history is cached.
    static func historyReachDays(candidates: [BrowserSearchResult], now: Date = Date()) -> Int? {
        var oldestBySource: [String: Date] = [:]
        for item in candidates where item.type == .history && item.timestamp >= CustomViewFilter.lastVisitFloor {
            let key = item.browserName + "\u{1F}" + (item.profileName ?? "")
            if let existing = oldestBySource[key], existing <= item.timestamp { continue }
            oldestBySource[key] = item.timestamp
        }
        guard let reach = oldestBySource.values.map({ now.timeIntervalSince($0) }).min() else { return nil }
        return max(1, Int((reach / 86_400).rounded(.down)))
    }

    /// The secondary line under the Last visited control; nil for Any.
    static func lastVisitedHint(rule: LastVisitedRule, historyReachDays: Int?) -> String? {
        if rule == .any { return nil }
        var hint = historyReachDays.map { "Based on your recent history (about \($0) \($0 == 1 ? "day" : "days"))." }
            ?? "Based on recent history."
        if case .olderThan = rule {
            // Unknown last visits never match a time rule (CustomViewFilter).
            hint += " Bookmarks not opened in that time are left out."
        }
        return hint
    }

    /// A fresh "New View" draft: everything shown, no filters.
    init(id: UUID = UUID()) {
        self.init(view: CustomView(id: id, name: "", types: CustomView.allowedTypes))
    }

    init(view: CustomView) {
        id = view.id
        name = view.name
        iconName = view.iconName.isEmpty ? CustomView.defaultIconName : view.iconName
        types = view.effectiveTypes
        profiles = view.profiles
        domainsText = view.domains.joined(separator: ", ")
        keywords = view.keywords
        lastVisited = view.lastVisited
        pinned = view.pinned
        semanticPrompt = view.semanticPrompt
        groupBy = view.groupBy
    }

    // MARK: Domains

    /// Non-empty entries of `domainsText`, trimmed, in typed order.
    var domainEntries: [String] {
        domainsText
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Entries that don't normalize to a plausible host ("https://", "a$b").
    var invalidDomains: [String] {
        domainEntries.filter { Self.normalizedDomain($0) == nil }
    }

    /// Valid entries, normalized and deduped (what gets saved).
    var normalizedDomains: [String] {
        var seen = Set<String>()
        return domainEntries.compactMap(Self.normalizedDomain).filter { seen.insert($0).inserted }
    }

    /// `CustomViewDomain.normalize`, plus a character check so typos that
    /// can't be a host are reported instead of silently matching nothing.
    /// `*wildcard*` / `/regex/` host patterns are kept as typed (a broken regex is invalid).
    static func normalizedDomain(_ raw: String) -> String? {
        if CustomViewDomain.isPattern(raw) { return TextPattern.normalize(raw) }
        guard let host = CustomViewDomain.normalize(raw) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._[]:"))
        guard host.unicodeScalars.allSatisfy(allowed.contains),
              host.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return host
    }

    // MARK: Validation

    enum Issue: Equatable {
        case nameRequired
        case noTypes
        case invalidDomains([String])

        var message: String {
            switch self {
            case .nameRequired: return "Give the view a name."
            case .noTypes: return "Show at least one of Tabs, Bookmarks or History."
            case .invalidDomains(let entries):
                return "Not a domain: " + entries.joined(separator: ", ")
            }
        }
    }

    var issues: [Issue] {
        var issues: [Issue] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.nameRequired) }
        if types.intersection(CustomView.allowedTypes).isEmpty { issues.append(.noTypes) }
        let invalid = invalidDomains
        if !invalid.isEmpty { issues.append(.invalidDomains(invalid)) }
        return issues
    }

    var isValid: Bool { issues.isEmpty }

    // MARK: Output

    /// The view this draft describes, best effort (invalid domain entries
    /// dropped, no types → all). Drives the live match count while typing.
    var previewView: CustomView {
        var seenProfiles = Set<String>()
        let profiles = self.profiles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenProfiles.insert($0.lowercased()).inserted }
        return CustomView(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            iconName: iconName.isEmpty ? CustomView.defaultIconName : iconName,
            types: types,
            profiles: profiles,
            domains: normalizedDomains,
            keywords: keywords.trimmingCharacters(in: .whitespacesAndNewlines),
            lastVisited: lastVisited,
            pinned: pinned,
            semanticPrompt: semanticPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            groupBy: groupBy
        )
    }

    /// The view to save; nil while the draft is invalid.
    var savableView: CustomView? {
        isValid ? previewView : nil
    }

    // MARK: Profiles

    func isProfileSelected(_ name: String) -> Bool {
        profiles.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    mutating func toggleProfile(_ name: String) {
        if isProfileSelected(name) {
            profiles.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        } else {
            profiles.append(name)
        }
    }
}

// MARK: - Profile options

/// One profile chip in the builder. Profiles match by name only
/// (`CustomViewFilter`), so the same name in two browsers is one chip.
struct CustomViewProfileOption: Identifiable, Hashable {
    let name: String
    /// Browsers the name was seen in (empty for a saved profile not seen now).
    let browsers: [String]
    /// Whether to name the browser(s) on the chip.
    let showsBrowsers: Bool

    var id: String { name.lowercased() }

    var label: String {
        guard showsBrowsers, !browsers.isEmpty else { return name }
        return "\(name) · \(browsers.joined(separator: ", "))"
    }

    /// Chips for the profiles present in `candidates`, plus any `selected`
    /// one no longer present (so it can still be unticked). Browser names
    /// are shown when profiles come from more than one browser — otherwise
    /// "Default" / "Person 1" are ambiguous.
    static func options(from candidates: [BrowserSearchResult], selected: [String]) -> [CustomViewProfileOption] {
        var order: [String] = []
        var names: [String: String] = [:]
        var browsers: [String: Set<String>] = [:]
        for item in candidates {
            guard let raw = item.profileName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let key = raw.lowercased()
            if names[key] == nil {
                names[key] = raw
                order.append(key)
            }
            if !item.browserName.isEmpty { browsers[key, default: []].insert(item.browserName) }
        }
        for raw in selected {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, names[key] == nil else { continue }
            names[key] = trimmed
            order.append(key)
        }
        let allBrowsers = browsers.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let showsBrowsers = allBrowsers.count > 1
        return order
            .map { key in
                CustomViewProfileOption(
                    name: names[key] ?? key,
                    browsers: (browsers[key] ?? []).sorted(),
                    showsBrowsers: showsBrowsers
                )
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}

// MARK: - Summary

extension CustomView {
    /// One-line description of the filters for lists ("Tabs · github.com ·
    /// Within 7 days · AI"). Unconstrained fields are omitted.
    var filterSummary: String {
        var parts: [String] = []

        let shown = CustomViewDraft.typeOrder.filter { effectiveTypes.contains($0) }
        if shown.count < CustomView.allowedTypes.count {
            parts.append(shown.map(Self.pluralLabel).joined(separator: " + "))
        }

        let profiles = self.profiles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if profiles.count > 2 {
            parts.append("\(profiles.count) profiles")
        } else if !profiles.isEmpty {
            parts.append(profiles.joined(separator: ", "))
        }

        var seen = Set<String>()
        let domains = self.domains.compactMap(CustomViewDomain.normalize).filter { seen.insert($0).inserted }
        if let first = domains.first {
            parts.append(domains.count > 1 ? "\(first) +\(domains.count - 1)" : first)
        }

        let words = keywords.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { parts.append("“\(words)”") }

        switch self.pinned {
        case .any: break
        case .only: parts.append("Pinned")
        case .exclude: parts.append("Not pinned")
        }
        if self.lastVisited != .any { parts.append(self.lastVisited.displayName) }
        if hasSemanticFilter { parts.append("AI") }

        return parts.isEmpty ? "All tabs, bookmarks and history" : parts.joined(separator: " · ")
    }

    static func pluralLabel(_ type: BrowserResultType) -> String {
        switch type {
        case .tab: return "Tabs"
        case .bookmark: return "Bookmarks"
        case .history: return "History"
        case .sent, .fastTabList: return type.label
        }
    }
}
