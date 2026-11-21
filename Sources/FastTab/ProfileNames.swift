import Foundation

/// A Chromium profile has two names: its folder ("Profile 3", for file access and
/// `--profile-directory`) and the name the person gave it ("SSV", from `Local State`). Results show
/// the display name and keep the folder beside it (`BrowserSearchResult.profileDirectory`); anything
/// stored (saved views, phone commands, tab slots) may hold either. These helpers treat both names as
/// the same profile. Pure, Foundation only (its tests also run on Linux).
enum ProfileNames {
    /// One profile as seen on one result (either name may be unknown).
    struct Source: Equatable, Sendable {
        let browserName: String
        let displayName: String?
        let directory: String?
    }

    /// Comparison key: trimmed and lowercased; nil when blank.
    static func key(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    /// Keys of a saved view's profile list (blank entries dropped).
    static func keys(_ names: [String]) -> Set<String> {
        Set(names.compactMap(key))
    }

    /// Whether a row known by `displayName` / `directory` belongs to one of the selected profiles.
    /// An empty selection means any profile.
    static func matches(selectedKeys: Set<String>, displayName: String?, directory: String?) -> Bool {
        guard !selectedKeys.isEmpty else { return true }
        return [displayName, directory].contains { key($0).map(selectedKeys.contains) ?? false }
    }

    /// The profile a stored reference names: exact folder first, then display name, then folder
    /// ignoring case. Nil for blank or unknown references.
    static func pick<P>(
        _ reference: String?,
        in profiles: [P],
        directory: (P) -> String,
        displayName: (P) -> String
    ) -> P? {
        guard let wanted = key(reference), let trimmed = reference?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return profiles.first { directory($0) == trimmed }
            ?? profiles.first { key(displayName($0)) == wanted }
            ?? profiles.first { key(directory($0)) == wanted }
    }
}

// MARK: - Custom view profile menu

/// One profile chip in the custom view builder. Profiles match by name only (`CustomViewFilter`), so
/// the same name in two browsers is one chip. `aliases` are the folder names seen for it ("Profile 3"
/// for "SSV"), so a view saved with the folder name ticks this chip instead of adding a second one.
struct CustomViewProfileOption: Identifiable, Hashable {
    let name: String
    /// Browsers the name was seen in (empty for a saved profile not seen now).
    let browsers: [String]
    /// Whether to name the browser(s) on the chip.
    let showsBrowsers: Bool
    /// Other names of the same profile (its folder), as seen on results.
    let aliases: [String]

    init(name: String, browsers: [String], showsBrowsers: Bool, aliases: [String] = []) {
        self.name = name
        self.browsers = browsers
        self.showsBrowsers = showsBrowsers
        self.aliases = aliases
    }

    var id: String { name.lowercased() }

    var label: String {
        guard showsBrowsers, !browsers.isEmpty else { return name }
        return "\(name) · \(browsers.joined(separator: ", "))"
    }

    /// Whether this chip's profile is in `selected` under any of its names.
    func isSelected(in selected: [String]) -> Bool {
        selected.contains(where: answers(to:))
    }

    /// `selected` with this profile ticked or unticked; unticking removes every name it goes by.
    func toggled(in selected: [String]) -> [String] {
        guard isSelected(in: selected) else { return selected + [name] }
        return selected.filter { !answers(to: $0) }
    }

    /// Whether a saved selection (display or folder name, any case) is one of this chip's names.
    func answers(to other: String) -> Bool {
        guard let wanted = ProfileNames.key(other) else { return false }
        return ([name] + aliases).contains { ProfileNames.key($0) == wanted }
    }

    /// Chips for the profiles in `sources`, plus any `selected` one no longer present (so it can still
    /// be unticked). Browser names are shown when profiles come from more than one browser, since
    /// "Default" / "Person 1" are otherwise ambiguous.
    static func options(from sources: [ProfileNames.Source], selected: [String]) -> [CustomViewProfileOption] {
        var order: [String] = []
        var names: [String: String] = [:]
        var browsers: [String: Set<String>] = [:]
        var aliases: [String: [String]] = [:]
        for source in sources {
            guard let raw = source.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            let key = raw.lowercased()
            if names[key] == nil {
                names[key] = raw
                order.append(key)
            }
            if !source.browserName.isEmpty { browsers[key, default: []].insert(source.browserName) }
            if let folder = source.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty,
               folder.lowercased() != key,
               !aliases[key, default: []].contains(where: { $0.caseInsensitiveCompare(folder) == .orderedSame }) {
                aliases[key, default: []].append(folder)
            }
        }
        // A folder name that is also a display name ("Default" named "Default") stays that chip's.
        let aliasOwner = aliases.reduce(into: [String: String]()) { owners, entry in
            for folder in entry.value where owners[folder.lowercased()] == nil { owners[folder.lowercased()] = entry.key }
        }
        for raw in selected {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, names[key] == nil, aliasOwner[key] == nil else { continue }
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
                    showsBrowsers: showsBrowsers,
                    aliases: (aliases[key] ?? []).filter { names[$0.lowercased()] == nil }
                )
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
}
