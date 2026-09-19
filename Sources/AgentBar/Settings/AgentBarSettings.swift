import Foundation
import Combine

/// Everything the user can configure, backed by UserDefaults (`.standard` in
/// the app; a scratch suite in tests). The Settings window edits it; the
/// coordinator watches the published values and applies them live.
///
/// Values are validated on the way in, so what is published is always usable.
@MainActor
final class AgentBarSettings: ObservableObject {
    static let showsMenuBarIconKey = "showsMenuBarIcon"
    static let showsCornerTabKey = "showsCornerTab"

    @Published private(set) var list: AgentListSettings
    @Published private(set) var showsMenuBarIcon: Bool
    /// The corner tab that peeks in when an agent starts needing the user.
    @Published private(set) var showsCornerTab: Bool
    @Published private(set) var hotkey: AgentHotkeyConfig
    @Published private(set) var dashboardBaseURL: URL

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        list = AgentListSettings.load(from: defaults)
        showsMenuBarIcon = defaults.object(forKey: Self.showsMenuBarIconKey) as? Bool ?? true
        showsCornerTab = defaults.object(forKey: Self.showsCornerTabKey) as? Bool ?? true
        hotkey = AgentHotkeyConfig.configured(defaults: defaults)
        dashboardBaseURL = DashboardEndpoint.configured(defaults: defaults).baseURL
    }

    func updateList(_ change: (inout AgentListSettings) -> Void) {
        var updated = list
        change(&updated)
        guard updated != list else { return }
        list = updated
        updated.save(to: defaults)
    }

    func setShowsMenuBarIcon(_ shows: Bool) {
        guard shows != showsMenuBarIcon else { return }
        showsMenuBarIcon = shows
        defaults.set(shows, forKey: Self.showsMenuBarIconKey)
    }

    func setShowsCornerTab(_ shows: Bool) {
        guard shows != showsCornerTab else { return }
        showsCornerTab = shows
        defaults.set(shows, forKey: Self.showsCornerTabKey)
    }

    /// Records the shortcut that is now actually registered.
    func commitHotkey(_ config: AgentHotkeyConfig) {
        hotkey = config
        config.save(to: defaults)
    }

    /// Saves a dashboard address if it is valid; the default address is stored
    /// as "no override". Invalid text changes nothing and says why.
    @discardableResult
    func applyDashboardAddress(_ text: String) -> DashboardAddress.Validation {
        let validation = DashboardAddress.validate(text)
        guard case .valid(let url) = validation else { return validation }
        if url == DashboardEndpoint.defaultBaseURL {
            defaults.removeObject(forKey: DashboardEndpoint.baseURLDefaultsKey)
        } else {
            defaults.set(url.absoluteString, forKey: DashboardEndpoint.baseURLDefaultsKey)
        }
        dashboardBaseURL = url
        return validation
    }

    func resetDashboardAddress() {
        defaults.removeObject(forKey: DashboardEndpoint.baseURLDefaultsKey)
        dashboardBaseURL = DashboardEndpoint.defaultBaseURL
    }
}
