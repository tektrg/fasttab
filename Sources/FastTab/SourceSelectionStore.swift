import Foundation
import AppKit

/// Identifies the four data sources FastTab can search across.
///
/// `rawValue` is the persisted key in UserDefaults — do not rename without a
/// migration. `appName` matches the `BrowserBackend.appName` produced by the
/// corresponding backend so the selection set can gate backend construction
/// without a second mapping table.
enum SearchSource: String, CaseIterable, Identifiable, Sendable {
    case chrome
    case edge
    case brave
    case safari
    case finder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .edge:   return "Microsoft Edge"
        case .brave:  return "Brave Browser"
        case .safari: return "Safari"
        case .finder: return "Finder"
        }
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

    @Published private(set) var enabled: Set<SearchSource>

    /// Snapshot of `enabled` at process launch. Used by Settings to detect
    /// whether a restart is required to apply the user's changes.
    let launchSnapshot: Set<SearchSource>

    init(defaults: UserDefaults = .standard) {
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
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
    }

    /// Returns the persisted set on second+ launches; otherwise auto-detects
    /// installed apps (Finder always counts) and writes the seed back so the
    /// "Sources" Settings section reflects the same state on next launch.
    private static func load(from defaults: UserDefaults) -> Set<SearchSource> {
        if defaults.bool(forKey: seededKey),
           let raw = defaults.array(forKey: defaultsKey) as? [String] {
            return Set(raw.compactMap { SearchSource(rawValue: $0) })
        }

        let detected = Set(SearchSource.allCases.filter { $0.isInstalled })
        defaults.set(detected.map { $0.rawValue }.sorted(), forKey: defaultsKey)
        defaults.set(true, forKey: seededKey)
        return detected
    }
}
