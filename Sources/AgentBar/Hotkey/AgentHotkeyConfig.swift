import AppKit
import CommandBarKit

/// The summon shortcut, stored in AgentBar's own UserDefaults domain
/// (`com.trungluong.AgentBar`). Settings > Shortcuts edits it; it can also be
/// set from the terminal (the two key/modifier keys are what the UI writes too):
///
///     defaults write com.trungluong.AgentBar hotkeyKeyCode -int 49      # Space
///     defaults write com.trungluong.AgentBar hotkeyModifiers -int 3     # ⌘⌥
///
/// - `hotkeyKeyCode`: Carbon virtual key code (Tab = 48, Space = 49, `~`/`` ` `` = 50).
/// - `hotkeyModifiers`: bit set, 1 = ⌘, 2 = ⌥, 4 = ⌃, 8 = ⇧. Must include at
///   least one modifier (a bare key would steal it from every app).
/// - `hotkeyKeyName` (optional, written by the UI): how the key is shown, e.g. "Space".
///
/// Missing, malformed or out-of-range values fall back to ⌥Tab. Cycling
/// backward uses the same key with ⇧ added (⌥⇧Tab). The app applies a change
/// made in the UI immediately; a `defaults write` needs a relaunch.
struct AgentHotkeyConfig: Equatable {
    static let keyCodeDefaultsKey = "hotkeyKeyCode"
    static let modifiersDefaultsKey = "hotkeyModifiers"
    static let keyNameDefaultsKey = "hotkeyKeyName"

    static let tabKeyCode: UInt16 = 48
    /// Highest Carbon virtual key code on Apple keyboards is well below this.
    private static let maxKeyCode = 127

    static let standard = AgentHotkeyConfig(keyCode: tabKeyCode, modifiers: [.option])

    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    /// How the key is shown ("Tab", "Space", "K"). Not part of equality: the same
    /// physical shortcut is the same shortcut however it was named.
    let keyName: String

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyName: String? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
        self.keyName = keyName.flatMap { $0.isEmpty ? nil : $0 } ?? KeyDisplayName.name(forKeyCode: keyCode)
    }

    static func == (lhs: AgentHotkeyConfig, rhs: AgentHotkeyConfig) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }

    /// The configured shortcut, or ⌥Tab when unset or invalid.
    /// Pass `.standard` (UserDefaults) in the app.
    static func configured(defaults: UserDefaults = .standard) -> AgentHotkeyConfig {
        guard let keyCode = defaults.object(forKey: keyCodeDefaultsKey) as? Int,
              (0...maxKeyCode).contains(keyCode),
              let modifierBits = defaults.object(forKey: modifiersDefaultsKey) as? Int,
              let modifiers = modifiers(fromBits: modifierBits)
        else { return .standard }
        return AgentHotkeyConfig(
            keyCode: UInt16(keyCode), modifiers: modifiers,
            keyName: defaults.string(forKey: keyNameDefaultsKey)
        )
    }

    /// What a key press recorded in the UI means as a shortcut; nil when it has
    /// no modifier (a bare key would steal it from every app).
    static func recorded(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyName: String) -> AgentHotkeyConfig? {
        guard ViewShortcut.isValid(modifiers: modifiers), Int(keyCode) <= maxKeyCode else { return nil }
        return AgentHotkeyConfig(keyCode: keyCode, modifiers: modifiers, keyName: keyName)
    }

    /// Persists this shortcut; `.standard` is stored by removing the keys, so a
    /// reset leaves the defaults domain as if it were never customised.
    func save(to defaults: UserDefaults = .standard) {
        guard self != .standard else {
            [Self.keyCodeDefaultsKey, Self.modifiersDefaultsKey, Self.keyNameDefaultsKey].forEach(defaults.removeObject(forKey:))
            return
        }
        defaults.set(Int(keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.set(modifierBits, forKey: Self.modifiersDefaultsKey)
        defaults.set(keyName, forKey: Self.keyNameDefaultsKey)
    }

    /// Same key plus ⇧, for cycling backward. Nil when ⇧ is already part of the
    /// main shortcut (the two would collide).
    var backwardModifiers: NSEvent.ModifierFlags? {
        modifiers.contains(.shift) ? nil : modifiers.union(.shift)
    }

    /// The backward-cycle shortcut as text, e.g. "⌥⇧Tab"; nil when unavailable.
    var backwardDisplayName: String? {
        backwardModifiers.map { ViewShortcut.modifierSymbols(for: $0) + keyName }
    }

    /// Human-readable, e.g. "⌥Tab".
    var displayName: String {
        ViewShortcut.modifierSymbols(for: modifiers) + keyName
    }

    private var modifierBits: Int {
        var bits = 0
        if modifiers.contains(.command) { bits |= 1 }
        if modifiers.contains(.option) { bits |= 2 }
        if modifiers.contains(.control) { bits |= 4 }
        if modifiers.contains(.shift) { bits |= 8 }
        return bits
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
