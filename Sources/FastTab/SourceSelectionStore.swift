import Foundation
import AppKit

/// Identifies the data sources FastTab can search across: the built-in
/// browsers/Finder plus any auto-detected Chromium-family browser (e.g. Ardia).
///
/// `rawValue` is the persisted key in UserDefaults — do not rename built-in
/// keys without a migration. `displayName` matches the `BrowserBackend.appName`
/// produced by the corresponding backend so the selection set can gate backend
/// construction without a second mapping table.
enum SearchSource: Hashable, Identifiable, Sendable {
    case chrome
    case edge
    case brave
    case safari
    case finder
    case customChromium(ChromiumBrowserSpec)

    private static let customPrefix = "chromium:"

    static var allCases: [SearchSource] {
        [.chrome, .edge, .brave]
            + ChromiumBrowserSpec.discoveredCustom.map { .customChromium($0) }
            + [.safari, .finder]
    }

    var rawValue: String {
        switch self {
        case .chrome: return "chrome"
        case .edge:   return "edge"
        case .brave:  return "brave"
        case .safari: return "safari"
        case .finder: return "finder"
        case .customChromium(let spec): return Self.customPrefix + spec.bundleIdentifier
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "chrome": self = .chrome
        case "edge":   self = .edge
        case "brave":  self = .brave
        case "safari": self = .safari
        case "finder": self = .finder
        default:
            guard rawValue.hasPrefix(Self.customPrefix) else { return nil }
            let bundleID = String(rawValue.dropFirst(Self.customPrefix.count))
            guard let spec = ChromiumBrowserSpec.discoveredCustom.first(where: { $0.bundleIdentifier == bundleID }) else {
                return nil
            }
            self = .customChromium(spec)
        }
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .edge:   return "Microsoft Edge"
        case .brave:  return "Brave Browser"
        case .safari: return "Safari"
        case .finder: return "Finder"
        case .customChromium(let spec): return spec.appName
        }
    }

    /// Short name for inline copy ("Open a tab in Chrome or Safari…").
    var shortName: String {
        switch self {
        case .chrome: return "Chrome"
        case .edge:   return "Edge"
        case .brave:  return "Brave"
        case .safari: return "Safari"
        case .finder: return "Finder"
        case .customChromium(let spec): return spec.shortName
        }
    }

    /// Subtitle for the empty Recents view, naming only the sources the
    /// user actually searches (in `allCases` order).
    static func recentsEmptyHint(enabled: Set<SearchSource>) -> String {
        let browserNames = allCases.filter { $0 != .finder && enabled.contains($0) }.map(\.shortName)
        guard !browserNames.isEmpty else {
            return enabled.contains(.finder)
                ? "Open a Finder window and try again."
                : "Turn on a browser in Settings › Sources."
        }
        return "Open a tab in \(browserNames.joinedAsNaturalList(conjunction: "or")) and try again."
    }

    /// Bundle ID used for install detection. Finder ships with macOS, so it
    /// has an ID but `isInstalled` always returns true.
    var bundleIdentifier: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .edge:   return "com.microsoft.edgemac"
        case .brave:  return "com.brave.Browser"
        case .safari: return "com.apple.Safari"
        case .finder: return "com.apple.finder"
        case .customChromium(let spec): return spec.bundleIdentifier
        }
    }

    /// Symbol used in the onboarding picker. Browsers fall back to a generic
    /// glyph; Finder gets the folder symbol that matches its scope chip
    /// (`SearchScope.swift`).
    var symbolName: String {
        switch self {
        case .finder: return "folder"
        default:      return "globe"
        }
    }

    var isInstalled: Bool {
        if self == .finder { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}

/// UserDefaults-backed observable set of enabled `SearchSource`s.
///
/// Read once at `BrowserTabService.init` to decide which backends to
/// construct. Mutating in Settings does **not** rebuild backends in place —
/// the Settings UI shows a "Restart FastTab to apply" banner instead, which
/// mirrors the existing Full Disk Access flow.
@MainActor
final class SourceSelectionStore: ObservableObject {
    static let shared = SourceSelectionStore()

    private static let defaultsKey = "FastTab.enabledSources.v1"
    private static let seededKey = "FastTab.enabledSources.v1.seeded"
    /// Tracks auto-discovered Chromium browsers that have already been offered
    /// to the user so newly installed browsers auto-enable once, while a
    /// browser the user explicitly turned off stays off.
    private static let seenDiscoveredKey = "FastTab.seenDiscoveredSources.v1"

    private let defaults: UserDefaults
    @Published private(set) var enabled: Set<SearchSource>

    /// Snapshot of `enabled` at process launch. Used by Settings to detect
    /// whether a restart is required to apply the user's changes.
    let launchSnapshot: Set<SearchSource>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = Self.load(from: defaults)
        self.enabled = stored
        self.launchSnapshot = stored
    }

    func isEnabled(_ source: SearchSource) -> Bool {
        enabled.contains(source)
    }

    func setEnabled(_ source: SearchSource, _ on: Bool) {
        var next = enabled
        if on { next.insert(source) } else { next.remove(source) }
        guard next != enabled else { return }
        enabled = next
        persist()
    }

    /// True when the current selection differs from what was loaded at launch
    /// — i.e. a restart is needed for the change to take effect.
    var needsRestartToApply: Bool {
        enabled != launchSnapshot
    }

    private func persist() {
        let raw = enabled.map { $0.rawValue }.sorted()
        defaults.set(raw, forKey: Self.defaultsKey)
    }

    /// Returns the persisted set on second+ launches (auto-enabling any newly
    /// discovered Chromium browser that hasn't been seen before); otherwise
    /// auto-detects installed apps (Finder always counts) and writes the seed
    /// back so the "Sources" Settings section reflects the same state on next launch.
    private static func load(from defaults: UserDefaults) -> Set<SearchSource> {
        let discoveredCustom = ChromiumBrowserSpec.discoveredCustom.map { SearchSource.customChromium($0) }

        if defaults.bool(forKey: seededKey),
           let raw = defaults.array(forKey: defaultsKey) as? [String] {
            var loaded = Set(raw.compactMap { SearchSource(rawValue: $0) })

            // Auto-enable newly installed Chromium browsers once when using the
            // real store (and only when the user hasn't explicitly cleared all
            // sources). Record them in `seenDiscoveredKey` so disabling one in
            // Settings sticks.
            if !loaded.isEmpty, !discoveredCustom.isEmpty {
                var seen = Set(defaults.array(forKey: seenDiscoveredKey) as? [String] ?? [])
                var didAdd = false
                for source in discoveredCustom where !seen.contains(source.rawValue) {
                    loaded.insert(source)
                    seen.insert(source.rawValue)
                    didAdd = true
                }
                if didAdd {
                    defaults.set(loaded.map(\.rawValue).sorted(), forKey: defaultsKey)
                    defaults.set(Array(seen).sorted(), forKey: seenDiscoveredKey)
                }
            }
            return loaded
        }

        let detected = Set(SearchSource.allCases.filter { $0.isInstalled })
        defaults.set(detected.map { $0.rawValue }.sorted(), forKey: defaultsKey)
        defaults.set(true, forKey: seededKey)
        defaults.set(discoveredCustom.map(\.rawValue).sorted(), forKey: seenDiscoveredKey)
        return detected
    }
}

extension Array where Element == String {
    /// "A", "A and B", "A, B and C" — English copy, no Oxford comma.
    func joinedAsNaturalList(conjunction: String) -> String {
        guard let last, count > 1 else { return last ?? "" }
        return dropLast().joined(separator: ", ") + " \(conjunction) " + last
    }
}
