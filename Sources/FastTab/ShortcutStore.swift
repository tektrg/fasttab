import AppKit
import Combine

@MainActor
class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var keyCode: UInt16
    @Published private(set) var modifiers: NSEvent.ModifierFlags
    @Published private(set) var keyDisplayName: String

    private init() {
        // Default: Cmd+Shift+Space
        UserDefaults.standard.register(defaults: [
            "shortcut.keyCode": 49,
            "shortcut.modifiers": Int(NSEvent.ModifierFlags([.command, .shift]).rawValue),
            "shortcut.keyName": "Space"
        ])
        keyCode = UInt16(UserDefaults.standard.integer(forKey: "shortcut.keyCode"))
        modifiers = NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "shortcut.modifiers")))
        keyDisplayName = UserDefaults.standard.string(forKey: "shortcut.keyName") ?? "Space"
    }

    func update(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyDisplayName = keyName
        UserDefaults.standard.set(Int(keyCode), forKey: "shortcut.keyCode")
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: "shortcut.modifiers")
        UserDefaults.standard.set(keyName, forKey: "shortcut.keyName")
    }

    var modifierSymbols: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option)  { result += "⌥" }
        if modifiers.contains(.shift)   { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    var displayString: String {
        modifierSymbols + keyDisplayName
    }

    static func isValid(modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.command, .shift, .option, .control]).isEmpty
    }

    static func keyName(for event: NSEvent) -> String {
        switch event.keyCode {
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
        default:  return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}
