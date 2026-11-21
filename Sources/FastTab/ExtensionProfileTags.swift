import Foundation
import IndieBrowserTabs

/// Names the browser profile behind an extension connection. Each profile's copy of the
/// companion extension keeps a random tag (`ftp-…`) in its own `chrome.storage.local`, which
/// the browser writes under `<support>/<profile dir>/Local Extension Settings/`. Finding the
/// folder holding the tag gives the profile directory, and Local State gives its display name
/// ("AptusFit"). Why: window titles don't carry the profile in Edge, so the window chip could
/// only show a window name.
///
/// Lookups are cached; a miss is retried at most every 30s (the browser may not have flushed
/// a brand-new tag to disk yet). Thread-safe.
final class ExtensionProfileTags: @unchecked Sendable {
    static let shared = ExtensionProfileTags()

    private let lock = NSLock()
    private var profiles: [String: BrowserProfile] = [:]
    private var lastMiss: [String: Date] = [:]
    private var inFlight: Set<String> = []

    /// The cached profile (folder + display name), or nil (and a background lookup is started).
    func profile(tag: String, supportDirectory: String) -> BrowserProfile? {
        guard tag.hasPrefix("ftp-") else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let profile = profiles[tag] { return profile }
        if inFlight.contains(tag) { return nil }
        if let miss = lastMiss[tag], Date().timeIntervalSince(miss) < 30 { return nil }
        inFlight.insert(tag)
        DispatchQueue.global(qos: .utility).async { [self] in
            let profile = Self.lookUpProfile(tag: tag, supportDirectory: supportDirectory)
            lock.lock()
            inFlight.remove(tag)
            if let profile { profiles[tag] = profile } else { lastMiss[tag] = Date() }
            lock.unlock()
        }
        return nil
    }

    /// The display name of the profile holding `tag` (its folder name when unnamed).
    static func lookUp(tag: String, supportDirectory: String) -> String? {
        lookUpProfile(tag: tag, supportDirectory: supportDirectory)?.displayName
    }

    static func lookUpProfile(tag: String, supportDirectory: String) -> BrowserProfile? {
        let base = URL(fileURLWithPath: (supportDirectory as NSString).expandingTildeInPath, isDirectory: true)
        guard let directory = ChromiumProfiles.directory(holding: tag, base: base) else { return nil }
        return BrowserProfile(directory: directory,
                              displayName: ChromiumProfiles.displayName(of: directory, base: base) ?? directory)
    }
}
