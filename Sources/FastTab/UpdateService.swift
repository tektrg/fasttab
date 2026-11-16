import IndieUpdate

/// Fast Tab's updater: IndieLibKit's `IndieUpdater` in inline mode (no Sparkle windows). The
/// command bar draws `status` as a banner (`bannerConfig(for:)`) and the menu-bar menu offers
/// "Check for Updates…" / "Update to vX". The launch check is a quiet background one
/// (`checkForUpdates(manual: false)`, `AppDelegate`, 5 s after launch).
@MainActor
enum UpdateService {
    /// How the banner names the app: "FastTab 1.7.0 is available."
    static let appName = "FastTab"
    /// Logs land in this subsystem, category "IndieUpdate".
    static let loggerSubsystem = "com.trungluong.FastTab"

    static let shared = IndieUpdater(mode: .inline, loggerSubsystem: loggerSubsystem)

    /// The command bar's update banner for `status`, nil when none shows.
    static func bannerConfig(for status: UpdateStatus) -> UpdateBannerConfig? {
        updateBannerConfig(status, appName: appName)
    }
}
