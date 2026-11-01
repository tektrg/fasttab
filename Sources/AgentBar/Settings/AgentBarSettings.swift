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
    nonisolated static let usesAvenirFontKey = "usesAvenirFont"
    nonisolated static let fontScaleKey = "fontScale"
    nonisolated static let fontScaleRange = 0.8...1.4

    /// Text-size multiplier (1.0 = designed size), clamped to `fontScaleRange`.
    nonisolated static func currentFontScale(_ defaults: UserDefaults = .standard) -> CGFloat {
        let raw = defaults.object(forKey: fontScaleKey) as? Double ?? 1.0
        return CGFloat(min(max(raw, fontScaleRange.lowerBound), fontScaleRange.upperBound))
    }

    @Published private(set) var list: AgentListSettings
    @Published private(set) var showsMenuBarIcon: Bool
    /// The corner tab: peeks in when an agent starts needing the user, and when the pointer rests
    /// in the bottom-right corner (both off when this is off). A click on it opens the panel.
    @Published private(set) var showsCornerTab: Bool
    /// Text face: Avenir Next (default) or the system font. Read by `Font.avenir`.
    @Published private(set) var usesAvenirFont: Bool
    @Published private(set) var fontScale: Double
    /// Whether an agent arriving in Needs you plays a sound, and which one per kind.
    @Published private(set) var sounds: SoundSettings
    /// Jev message-routing preferences (model id, what happens after a pick). The API key
    /// itself is not here — it lives in Keychain, see `RoutingAPIKeyStoring`.
    @Published private(set) var routing: RoutingSettings
    @Published private(set) var hotkey: AgentHotkeyConfig
    @Published private(set) var dashboardBaseURL: URL

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        list = AgentListSettings.load(from: defaults)
        showsMenuBarIcon = defaults.object(forKey: Self.showsMenuBarIconKey) as? Bool ?? true
        showsCornerTab = defaults.object(forKey: Self.showsCornerTabKey) as? Bool ?? true
        usesAvenirFont = defaults.object(forKey: Self.usesAvenirFontKey) as? Bool ?? true
        fontScale = Double(Self.currentFontScale(defaults))
        sounds = SoundSettings.load(from: defaults)
        routing = RoutingSettings.load(from: defaults)
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

    func setUsesAvenirFont(_ uses: Bool) {
        guard uses != usesAvenirFont else { return }
        usesAvenirFont = uses
        defaults.set(uses, forKey: Self.usesAvenirFontKey)
    }

    func setFontScale(_ scale: Double) {
        let clamped = (min(max(scale, Self.fontScaleRange.lowerBound), Self.fontScaleRange.upperBound) * 100).rounded() / 100
        guard clamped != fontScale else { return }
        fontScale = clamped
        defaults.set(clamped, forKey: Self.fontScaleKey)
    }

    func updateSounds(_ change: (inout SoundSettings) -> Void) {
        var updated = sounds
        change(&updated)
        guard updated != sounds else { return }
        sounds = updated
        updated.save(to: defaults)
    }

    func updateRouting(_ change: (inout RoutingSettings) -> Void) {
        var updated = routing
        change(&updated)
        guard updated != routing else { return }
        routing = updated
        updated.save(to: defaults)
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
