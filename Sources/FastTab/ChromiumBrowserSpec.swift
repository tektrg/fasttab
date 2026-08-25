import Foundation

/// One Chromium-family browser FastTab can read: the identity triple
/// `ChromiumBackend` needs (AppleScript app name, bundle id, Application
/// Support dir) plus the native-messaging manifest directory derived from it.
/// Single source of truth shared by `BrowserTabService.init` (backend
/// construction) and `NativeHostInstaller` (manifest install) so the two can
/// never drift on a browser's paths.
struct ChromiumBrowserSpec: Sendable {
    let source: SearchSource
    let appName: String
    let bundleIdentifier: String
    /// `~`-relative, matching how `ChromiumBackend` expands support dirs.
    let supportDirectory: String

    /// Where the browser looks for its native-messaging host manifests.
    var nativeMessagingHostsDirectory: String {
        supportDirectory + "/NativeMessagingHosts"
    }

    static let chrome = ChromiumBrowserSpec(
        source: .chrome,
        appName: "Google Chrome",
        bundleIdentifier: "com.google.Chrome",
        supportDirectory: "~/Library/Application Support/Google/Chrome"
    )

    static let edge = ChromiumBrowserSpec(
        source: .edge,
        appName: "Microsoft Edge",
        bundleIdentifier: "com.microsoft.edgemac",
        supportDirectory: "~/Library/Application Support/Microsoft Edge"
    )

    static let brave = ChromiumBrowserSpec(
        // appName must match Brave's AppleScript target and `.app` bundle name
        // ("Brave Browser"), not the colloquial "Brave".
        source: .brave,
        appName: "Brave Browser",
        bundleIdentifier: "com.brave.Browser",
        supportDirectory: "~/Library/Application Support/BraveSoftware/Brave-Browser"
    )

    /// Order matches the backend display order today: Chrome, Edge, Brave.
    static let all: [ChromiumBrowserSpec] = [.chrome, .edge, .brave]
}
