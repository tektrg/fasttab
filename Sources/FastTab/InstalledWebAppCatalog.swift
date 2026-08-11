import Foundation

/// A browser-installed "chromeless" web app — created via the browser's own
/// "Install as app" flow, backed by a real `.app` bundle under
/// `~/Applications` (e.g. `Chrome Apps.localized/Notion Calendar.app`).
struct InstalledWebApp: Identifiable, Sendable, Equatable {
    let name: String
    let homeURL: String
    /// `BrowserSearchResult.browserName` of the browser that owns this app —
    /// only history/bookmark clicks from that same browser may route here.
    let browserAppName: String
    /// The app's own bundle identifier, used to launch it via `open -b`.
    let appBundleIdentifier: String

    var id: String { appBundleIdentifier }
}

/// Scans disk for installed web apps and caches the result. There is no
/// browser API for this list — the apps only exist as bundles on disk.
@MainActor
final class InstalledWebAppCatalog: ObservableObject {
    static let shared = InstalledWebAppCatalog()

    @Published private(set) var apps: [InstalledWebApp] = []

    private var lastScanAt: Date = .distantPast
    private let rescanInterval: TimeInterval = 30

    /// Maps each Chromium-family browser's own bundle id to the display name
    /// used throughout FastTab as `browserName` — reusing `SearchSource`
    /// rather than a second hand-maintained table.
    private nonisolated static let browserAppNameByOwningBundleID: [String: String] =
        Dictionary(uniqueKeysWithValues: SearchSource.allCases
            .filter { $0 != .safari && $0 != .finder }
            .map { ($0.bundleIdentifier, $0.displayName) })

    private nonisolated static let scanRoots = ["~/Applications", "/Applications"]

    init() {
        rescan()
    }

    /// Called from the existing 30s cache-refresh cycle — installs are rare,
    /// so there's no need for a dedicated poll.
    func rescanIfNeeded() {
        guard Date().timeIntervalSince(lastScanAt) >= rescanInterval else { return }
        rescan()
    }

    private func rescan() {
        apps = Self.scanInstalledWebApps()
        lastScanAt = Date()
    }

    nonisolated static func scanInstalledWebApps() -> [InstalledWebApp] {
        scanRoots
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            .flatMap(appBundleCandidates(under:))
            .compactMap(parseWebApp(at:))
    }

    /// Finds `.app` bundles up to two levels deep — installed web apps live
    /// inside a container folder (e.g. `Chrome Apps.localized`), not directly
    /// under `~/Applications`.
    private nonisolated static func appBundleCandidates(under root: URL) -> [URL] {
        guard let topLevel = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [URL] = []
        for entry in topLevel {
            if entry.pathExtension == "app" {
                candidates.append(entry)
                continue
            }
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let nested = try? FileManager.default.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            candidates.append(contentsOf: nested.filter { $0.pathExtension == "app" })
        }
        return candidates
    }

    /// Reads the `Cr*` keys Chromium writes into an installed web app's
    /// `Info.plist`. Returns nil for anything that isn't a real http/https
    /// web app (e.g. Google Password Manager installs a `chrome://` shortcut
    /// the same way) or whose owning browser FastTab doesn't recognize.
    private nonisolated static func parseWebApp(at bundleURL: URL) -> InstalledWebApp? {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoPlistURL) else { return nil }

        guard let homeURL = info["CrAppModeShortcutURL"] as? String,
              let scheme = URL(string: homeURL)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let name = info["CrAppModeShortcutName"] as? String, !name.isEmpty else { return nil }
        guard let ownerBundleID = info["CrBundleIdentifier"] as? String,
              let browserAppName = browserAppNameByOwningBundleID[ownerBundleID] else {
            return nil
        }
        guard let appBundleIdentifier = info["CFBundleIdentifier"] as? String else { return nil }

        return InstalledWebApp(
            name: name,
            homeURL: homeURL,
            browserAppName: browserAppName,
            appBundleIdentifier: appBundleIdentifier
        )
    }
}
