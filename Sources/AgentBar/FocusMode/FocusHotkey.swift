import AppKit

/// Focus mode's system-wide shortcut. Default ⌥⇧F: it does not clash with the summon ⌥Tab /
/// ⌥⇧Tab pair, and F matches ⌘F inside the panel. Stored in AgentBar's own defaults domain:
///
///     defaults write com.trungluong.AgentBar focusHotkeyKeyCode -int 3      # F
///     defaults write com.trungluong.AgentBar focusHotkeyModifiers -int 10   # ⌥⇧
///
/// Same encoding as `AgentHotkeyConfig` (1 = ⌘, 2 = ⌥, 4 = ⌃, 8 = ⇧). Settings > Shortcuts edits it.
enum FocusHotkey {
    static let keys = AgentHotkeyConfig.DefaultsKeys(
        keyCode: "focusHotkeyKeyCode", modifiers: "focusHotkeyModifiers", keyName: "focusHotkeyKeyName"
    )
    static let fKeyCode: UInt16 = 3
    static let standard = AgentHotkeyConfig(keyCode: fKeyCode, modifiers: [.option, .shift], keyName: "F")

    static func configured(defaults: UserDefaults = .standard) -> AgentHotkeyConfig {
        AgentHotkeyConfig.configured(defaults: defaults, keys: keys, fallback: standard)
    }

    static func save(_ config: AgentHotkeyConfig, to defaults: UserDefaults = .standard) {
        config.save(to: defaults, keys: keys, standard: standard)
    }

    /// Plain-English problem when `focus` would take the summon shortcut or its ⇧ backward twin
    /// (one press would then fire both); nil when they are distinct.
    static func clashMessage(focus: AgentHotkeyConfig, summon: AgentHotkeyConfig) -> String? {
        let takesSummon = focus == summon
        let takesBackward = summon.backwardModifiers.map {
            focus == AgentHotkeyConfig(keyCode: summon.keyCode, modifiers: $0, keyName: summon.keyName)
        } ?? false
        guard takesSummon || takesBackward else { return nil }
        return "\(focus.displayName) is already AgentBar's switch shortcut. Pick another key."
    }

    /// A change refused before touching macOS because of a clash; nil = go ahead and register.
    static func resolveChange(previous: AgentHotkeyConfig, requested: AgentHotkeyConfig, summon: AgentHotkeyConfig) -> HotkeyChangeOutcome? {
        guard let clash = clashMessage(focus: requested, summon: summon) else { return nil }
        return .reverted(active: previous, message: "\(clash) Still using \(previous.displayName).")
    }
}
