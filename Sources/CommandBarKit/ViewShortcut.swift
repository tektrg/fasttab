import AppKit

/// A recorded keyboard shortcut: key code, raw modifier flags, and the key's
/// display name. Hosts own persistence (FastTab's `ShortcutStore` stores each
/// field under its own UserDefaults key); `Codable` is a convenience for hosts
/// that prefer to store the value whole.
public struct ViewShortcut: Equatable, Codable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt
    public var keyName: String

    public init(keyCode: UInt16, modifiers: UInt, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    public var modifierSymbols: String {
        Self.modifierSymbols(for: modifierFlags)
    }

    public var displayString: String {
        modifierSymbols + keyName
    }

    /// `⌃⌥⇧⌘` glyphs for `flags`, in the standard macOS menu order.
    public static func modifierSymbols(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option)  { result += "⌥" }
        if flags.contains(.shift)   { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    /// A global shortcut needs at least one of ⌘ ⇧ ⌥ ⌃.
    public static func isValid(modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.command, .shift, .option, .control]).isEmpty
    }

    /// Display name for the key pressed in `event`.
    public static func keyName(for event: NSEvent) -> String {
        keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
    }

    /// Display name for a key code; `characters` is the fallback for keys
    /// without a dedicated glyph.
    public static func keyName(keyCode: UInt16, characters: String?) -> String {
        switch keyCode {
        case 49:  return "Space"
        case 36:  return "↩"
        case 51:  return "⌫"
        case 117: return "⌦"
        case 48:  return "⇥"
        case 53:  return "⎋"
        case 126: return "↑"
        case 125: return "↓"
        case 123: return "←"
        case 124: return "→"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PgUp"
        case 121: return "PgDn"
        default:  return (characters ?? "?").uppercased()
        }
    }
}
