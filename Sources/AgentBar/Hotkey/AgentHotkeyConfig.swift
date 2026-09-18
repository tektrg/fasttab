import AppKit

/// The summon shortcut, stored in AgentBar's own UserDefaults domain
/// (`com.trungluong.AgentBar`), read once at launch. There is no settings UI
/// in v1; to change it:
///
///     defaults write com.trungluong.AgentBar hotkeyKeyCode -int 49      # Space
///     defaults write com.trungluong.AgentBar hotkeyModifiers -int 3     # ⌘⌥
///
/// - `hotkeyKeyCode`: Carbon virtual key code (Tab = 48, Space = 49, `~`/`` ` `` = 50).
/// - `hotkeyModifiers`: bit set, 1 = ⌘, 2 = ⌥, 4 = ⌃, 8 = ⇧. Must include at
///   least one modifier (a bare key would steal it from every app).
///
/// Missing, malformed or out-of-range values fall back to ⌥Tab. Cycling
/// backward uses the same key with ⇧ added (⌥⇧Tab).
struct AgentHotkeyConfig: Equatable {
    static let keyCodeDefaultsKey = "hotkeyKeyCode"
    static let modifiersDefaultsKey = "hotkeyModifiers"

    static let tabKeyCode: UInt16 = 48
    /// Highest Carbon virtual key code on Apple keyboards is well below this.
    private static let maxKeyCode = 127

    static let standard = AgentHotkeyConfig(keyCode: tabKeyCode, modifiers: [.option])

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    /// The configured shortcut, or ⌥Tab when unset or invalid.
    /// Pass `.standard` (UserDefaults) in the app.
    static func configured(defaults: UserDefaults = .standard) -> AgentHotkeyConfig {
        guard let keyCode = defaults.object(forKey: keyCodeDefaultsKey) as? Int,
              (0...maxKeyCode).contains(keyCode),
              let modifierBits = defaults.object(forKey: modifiersDefaultsKey) as? Int,
              let modifiers = modifiers(fromBits: modifierBits)
        else { return .standard }
        return AgentHotkeyConfig(keyCode: UInt16(keyCode), modifiers: modifiers)
    }

    /// Same key plus ⇧, for cycling backward. Nil when ⇧ is already part of the
    /// main shortcut (the two would collide).
    var backwardModifiers: NSEvent.ModifierFlags? {
        modifiers.contains(.shift) ? nil : modifiers.union(.shift)
    }

    /// Human-readable, e.g. "⌥Tab" (only for log lines and messages).
    var displayName: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
        return prefix + (keyCode == Self.tabKeyCode ? "Tab" : "key \(keyCode)")
    }

    private static func modifiers(fromBits bits: Int) -> NSEvent.ModifierFlags? {
        guard (1...15).contains(bits) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if bits & 1 != 0 { flags.insert(.command) }
        if bits & 2 != 0 { flags.insert(.option) }
        if bits & 4 != 0 { flags.insert(.control) }
        if bits & 8 != 0 { flags.insert(.shift) }
        return flags
    }
}
