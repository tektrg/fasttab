import Foundation
import AppKit

/// One Chromium-family browser FastTab can read: the identity triple
/// `ChromiumBackend` needs (AppleScript app name, bundle id, Application
/// Support dir) plus the native-messaging manifest directory derived from it.
/// Single source of truth shared by `BrowserTabService.init` (backend
/// construction) and `NativeHostInstaller` (manifest install) so the two can
/// never drift on a browser's paths.
struct ChromiumBrowserSpec: Hashable, Sendable {
    let appName: String
    let bundleIdentifier: String
    /// `~`-relative, matching how `ChromiumBackend` expands support dirs.
    let supportDirectory: String
    /// Short name for inline copy ("Chrome", "Ardia", ...).
    let shortName: String

    init(appName: String, bundleIdentifier: String, supportDirectory: String, shortName: String? = nil) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.supportDirectory = supportDirectory
        self.shortName = shortName ?? appName
    }

    var source: SearchSource {
        switch bundleIdentifier {
        case Self.chrome.bundleIdentifier: return .chrome
        case Self.edge.bundleIdentifier:   return .edge
        case Self.brave.bundleIdentifier:  return .brave
        default:                           return .customChromium(self)
        }
    }

    /// Where the browser looks for its native-messaging host manifests.
    var nativeMessagingHostsDirectory: String {
        supportDirectory + "/NativeMessagingHosts"
    }

    static let chrome = ChromiumBrowserSpec(
        appName: "Google Chrome",
        bundleIdentifier: "com.google.Chrome",
        supportDirectory: "~/Library/Application Support/Google/Chrome",
        shortName: "Chrome"
    )

    static let edge = ChromiumBrowserSpec(
        appName: "Microsoft Edge",
        bundleIdentifier: "com.microsoft.edgemac",
        supportDirectory: "~/Library/Application Support/Microsoft Edge",
        shortName: "Edge"
    )

    static let brave = ChromiumBrowserSpec(
        // appName must match Brave's AppleScript target and `.app` bundle name
        // ("Brave Browser"), not the colloquial "Brave".
        appName: "Brave Browser",
        bundleIdentifier: "com.brave.Browser",
        supportDirectory: "~/Library/Application Support/BraveSoftware/Brave-Browser",
        shortName: "Brave"
    )

    /// Core built-in Chromium browsers always shown in Settings/Onboarding even
    /// if not currently installed on this Mac.
    static let builtIn: [ChromiumBrowserSpec] = [.chrome, .edge, .brave]

    /// Known support directories for popular Chromium-based browsers that are
    /// auto-detected when installed on the user's Mac (including Ardia).
    static let knownSupportDirectoriesByBundleID: [String: String] = [
        "com.ardia.browser": "~/Library/Application Support/com.ardia.browser/Chromium",
        "company.thebrowser.Browser": "~/Library/Application Support/Arc/User Data",
        "company.thebrowser.dia": "~/Library/Application Support/Dia/User Data",
        "com.vivaldi.Vivaldi": "~/Library/Application Support/Vivaldi",
        "com.operasoftware.Opera": "~/Library/Application Support/com.operasoftware.Opera",
        "com.operasoftware.OperaGX": "~/Library/Application Support/com.operasoftware.OperaGX",
        "org.chromium.Chromium": "~/Library/Application Support/Chromium",
        "com.google.Chrome.canary": "~/Library/Application Support/Google/Chrome Canary",
        "com.google.Chrome.beta": "~/Library/Application Support/Google/Chrome Beta",
        "com.google.Chrome.dev": "~/Library/Application Support/Google/Chrome Dev",
        "com.microsoft.edgemac.Beta": "~/Library/Application Support/Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev": "~/Library/Application Support/Microsoft Edge Dev",
        "com.microsoft.edgemac.Canary": "~/Library/Application Support/Microsoft Edge Canary",
        "com.brave.Browser.beta": "~/Library/Application Support/BraveSoftware/Brave-Browser-Beta",
        "com.brave.Browser.nightly": "~/Library/Application Support/BraveSoftware/Brave-Browser-Nightly",
        "ai.perplexity.comet": "~/Library/Application Support/Comet",
        "net.imput.helium": "~/Library/Application Support/net.imput.helium"
    ]

    /// Built-in browsers plus any additional Chromium browsers auto-detected on
    /// this Mac (e.g. Ardia, Arc, Dia, Vivaldi, Opera, Helium, Comet, ...).
    /// Computed once per process launch (matching `BrowserTabService.init`'s
    /// launch-time backend list).
    static let discoveredCustom: [ChromiumBrowserSpec] = ChromiumBrowserDiscovery.discoverAdditionalInstalled()

    /// Order matches the backend display order: Chrome, Edge, Brave, followed by
    /// any auto-detected installed Chromium browsers sorted alphabetically.
    static var all: [ChromiumBrowserSpec] {
        builtIn + discoveredCustom
    }
}

/// Auto-detects installed Chromium-based web browsers on macOS so FastTab can
/// support browsers like Ardia, Arc, Dia, Vivaldi, Opera, Comet, Helium, etc.
/// without requiring a hardcoded release for each one.
enum ChromiumBrowserDiscovery {
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "app.zen-browser.zen",
        "com.kagi.kagimacOS" // WebKit-based (Orion)
    ]

    /// Finds installed Chromium-based browsers outside the core built-ins
    /// (Chrome, Edge, Brave).
    static func discoverAdditionalInstalled(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ChromiumBrowserSpec] {
        guard let httpsURL = URL(string: "https://example.com") else { return [] }
        let builtInIDs = Set(ChromiumBrowserSpec.builtIn.map(\.bundleIdentifier))
        let candidateURLs = NSWorkspace.shared.urlsForApplications(toOpen: httpsURL)

        var seenBundleIDs = Set<String>()
        var discovered: [ChromiumBrowserSpec] = []

        for rawURL in candidateURLs {
            guard let rawBundle = Bundle(url: rawURL),
                  let bundleID = rawBundle.bundleIdentifier,
                  !bundleID.isEmpty,
                  !builtInIDs.contains(bundleID),
                  !excludedBundleIDs.contains(bundleID),
                  seenBundleIDs.insert(bundleID).inserted else {
                continue
            }

            // Resolve the canonical installed bundle URL so mounted DMGs
            // (/Volumes/...) or updater copies are skipped in favor of /Applications.
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) ?? rawURL
            if appURL.path.hasPrefix("/Volumes/") { continue }

            guard isChromiumBrowserBundle(at: appURL, bundleIdentifier: bundleID) else { continue }

            let appName = appURL.deletingPathExtension().lastPathComponent
            let supportDir = resolveSupportDirectory(
                appName: appName,
                bundleIdentifier: bundleID,
                homeDirectory: homeDirectory
            )
            discovered.append(ChromiumBrowserSpec(
                appName: appName,
                bundleIdentifier: bundleID,
                supportDirectory: supportDir
            ))
        }

        return discovered.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    /// True when `appURL` is a Chromium-based browser bundle (and not an
    /// Electron app or non-Chromium browser).
    static func isChromiumBrowserBundle(at appURL: URL, bundleIdentifier: String) -> Bool {
        if ChromiumBrowserSpec.knownSupportDirectoriesByBundleID[bundleIdentifier] != nil {
            return true
        }
        let frameworksDir = appURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir.path) else {
            return false
        }
        // Electron apps ship `Electron Framework.framework`; never treat them as browsers.
        if entries.contains(where: { $0.caseInsensitiveCompare("Electron Framework.framework") == .orderedSame }) {
            return false
        }
        for entry in entries where entry.hasSuffix(".framework") {
            let lower = entry.lowercased()
            if lower.contains("chromium") || lower.contains("chrome") {
                return true
            }
            // Many Chromium forks rename the framework (e.g. `Vivaldi Framework.framework`,
            // `Opera Framework.framework`, `Dia Framework.framework`), but all keep Chromium's
            // `Versions/*/Helpers/*Helper*.app` structure inside.
            let versionsDir = frameworksDir.appendingPathComponent(entry).appendingPathComponent("Versions", isDirectory: true)
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path) {
                for version in versions where version != "Current" {
                    let helpersDir = versionsDir.appendingPathComponent(version).appendingPathComponent("Helpers", isDirectory: true)
                    if let helpers = try? FileManager.default.contentsOfDirectory(atPath: helpersDir.path),
                       helpers.contains(where: { $0.hasSuffix(".app") && $0.localizedCaseInsensitiveContains("Helper") }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Resolves a `~`-relative Chromium User Data directory for a browser.
    /// Checks known mappings first, then probes standard Application Support
    /// layouts for a directory containing `Local State` or a `Default` profile.
    static func resolveSupportDirectory(
        appName: String,
        bundleIdentifier: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if let known = ChromiumBrowserSpec.knownSupportDirectoriesByBundleID[bundleIdentifier] {
            return known
        }

        let appSupport = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        let candidateRelativePaths = [
            appName,
            "\(appName)/User Data",
            "\(appName)/Chromium",
            bundleIdentifier,
            "\(bundleIdentifier)/User Data",
            "\(bundleIdentifier)/Chromium"
        ]

        for relative in candidateRelativePaths {
            let dir = appSupport.appendingPathComponent(relative, isDirectory: true)
            if looksLikeChromiumUserDataDirectory(dir) {
                return "~/Library/Application Support/\(relative)"
            }
        }

        // Shallow scan (depth 2) for vendor-nested directories (e.g. `<Vendor>/<Browser>`
        // or `<Vendor>/<Browser>/User Data`) matching the app name or bundle ID.
        if let matchedRelative = scanApplicationSupportForBrowser(
            appSupport: appSupport,
            appName: appName,
            bundleIdentifier: bundleIdentifier
        ) {
            return "~/Library/Application Support/\(matchedRelative)"
        }

        // Fallback default even before first profile creation so NativeHostInstaller
        // has a deterministic location.
        return "~/Library/Application Support/\(appName)"
    }

    /// True when `directory` looks like a Chromium User Data root (contains
    /// `Local State` AND at least one profile folder with `History`/`Bookmarks`,
    /// or a `Default` profile folder with `History`/`Bookmarks`).
    static func looksLikeChromiumUserDataDirectory(_ directory: URL) -> Bool {
        let fm = FileManager.default
        let hasLocalState = fm.fileExists(atPath: directory.appendingPathComponent("Local State").path)
        let defaultDir = directory.appendingPathComponent("Default", isDirectory: true)
        let hasDefaultData = fm.fileExists(atPath: defaultDir.appendingPathComponent("History").path)
            || fm.fileExists(atPath: defaultDir.appendingPathComponent("Bookmarks").path)
        if hasDefaultData { return true }
        guard hasLocalState else { return false }
        guard let children = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        return children.contains { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && (fm.fileExists(atPath: child.appendingPathComponent("History").path)
                    || fm.fileExists(atPath: child.appendingPathComponent("Bookmarks").path))
        }
    }

    private static func scanApplicationSupportForBrowser(
        appSupport: URL,
        appName: String,
        bundleIdentifier: String
    ) -> String? {
        let fm = FileManager.default
        guard let topEntries = try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let appNameLower = appName.lowercased()
        let bundleLower = bundleIdentifier.lowercased()
        let bundleTail = bundleIdentifier.split(separator: ".").last.map { String($0).lowercased() } ?? ""

        func nameMatches(_ folderName: String) -> Bool {
            let lower = folderName.lowercased()
            return lower == appNameLower
                || lower == bundleLower
                || lower.contains(appNameLower)
                || (!bundleTail.isEmpty && bundleTail.count >= 3 && lower == bundleTail)
        }

        for top in topEntries {
            guard (try? top.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let topName = top.lastPathComponent
            if nameMatches(topName), looksLikeChromiumUserDataDirectory(top) {
                return topName
            }
            guard let subEntries = try? fm.contentsOfDirectory(at: top, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for sub in subEntries {
                guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let subName = sub.lastPathComponent
                if (nameMatches(topName) || nameMatches(subName)), looksLikeChromiumUserDataDirectory(sub) {
                    return "\(topName)/\(subName)"
                }
            }
        }
        return nil
    }
}
