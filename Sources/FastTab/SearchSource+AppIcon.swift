import AppKit

extension SearchSource {
    /// The installed app's icon, or `nil` when the app isn't installed.
    /// Cached: the onboarding source hero asks for it on every animation frame.
    @MainActor
    var appIconImage: NSImage? {
        if let cached = Self.appIconCache[self] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.appIconCache[self] = .some(icon)
        return icon
    }

    @MainActor private static var appIconCache: [SearchSource: NSImage?] = [:]
}
