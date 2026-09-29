import AppKit

extension SearchSource {
    /// The installed app's icon, or `nil` when the app isn't installed.
    /// Cached: the onboarding source hero asks for it on every animation frame.
    /// A found icon is kept for good; "not installed" is re-checked every few
    /// seconds, so an app installed mid-onboarding shows its icon.
    @MainActor
    var appIconImage: NSImage? {
        let now = Date()
        if let cached = Self.appIconCache[self], cached.icon != nil || now < cached.recheckAfter {
            return cached.icon
        }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.appIconCache[self] = (icon, now.addingTimeInterval(Self.notInstalledRecheckSeconds))
        return icon
    }

    private static let notInstalledRecheckSeconds: TimeInterval = 5
    @MainActor private static var appIconCache: [SearchSource: (icon: NSImage?, recheckAfter: Date)] = [:]
}
