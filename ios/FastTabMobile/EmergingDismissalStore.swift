import Foundation

/// Persists the user's "Not a read" choices for the Emerging feed: either a
/// single link or an entire website, hidden going forward. Local-only
/// (`UserDefaults.standard`), mirroring `LastOpenedStore`'s persistence shape.
@MainActor
public final class EmergingDismissalStore: ObservableObject {
    public static let shared = EmergingDismissalStore()

    @Published public private(set) var dismissedLinkKeys: Set<String> = []
    @Published public private(set) var dismissedHosts: Set<String> = []

    private static let linksDefaultsKey = "FastTabMobile.emergingDismissedLinksV1"
    private static let hostsDefaultsKey = "FastTabMobile.emergingDismissedHostsV1"

    private init() {
        loadFromDisk()
    }

    public func loadFromDisk() {
        dismissedLinkKeys = Set(UserDefaults.standard.stringArray(forKey: Self.linksDefaultsKey) ?? [])
        dismissedHosts = Set(UserDefaults.standard.stringArray(forKey: Self.hostsDefaultsKey) ?? [])
    }

    public func isDismissed(url: URL) -> Bool {
        let host = (url.host() ?? "").lowercased()
        if dismissedHosts.contains(host) { return true }
        return dismissedLinkKeys.contains(EmergingURLUtils.dedupeKey(url))
    }

    public func dismissLink(url: URL) {
        dismissedLinkKeys.insert(EmergingURLUtils.dedupeKey(url))
        persist()
    }

    public func dismissHost(url: URL) {
        let host = (url.host() ?? "").lowercased()
        guard !host.isEmpty else { return }
        dismissedHosts.insert(host)
        persist()
    }

    /// Undo — surfaced from Settings so a mis-tap isn't permanent.
    public func restoreHost(_ host: String) {
        dismissedHosts.remove(host)
        persist()
    }

    public func restoreLink(key: String) {
        dismissedLinkKeys.remove(key)
        persist()
    }

    public func clearAll() {
        dismissedLinkKeys.removeAll()
        dismissedHosts.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(dismissedLinkKeys), forKey: Self.linksDefaultsKey)
        UserDefaults.standard.set(Array(dismissedHosts), forKey: Self.hostsDefaultsKey)
    }
}
