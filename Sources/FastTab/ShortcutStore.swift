import AppKit
import Combine

struct ViewShortcut: Equatable, Codable {
    var keyCode: UInt16
    var modifiers: UInt
    var keyName: String

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    var modifierSymbols: String {
        var result = ""
        let flags = modifierFlags
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option)  { result += "⌥" }
        if flags.contains(.shift)   { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        return result
    }

    var displayString: String {
        modifierSymbols + keyName
    }
}

@MainActor
class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    // Primary / default view shortcut (keys: shortcut.keyCode, shortcut.modifiers, shortcut.keyName)
    @Published private(set) var keyCode: UInt16
    @Published private(set) var modifiers: NSEvent.ModifierFlags
    @Published private(set) var keyDisplayName: String

    // Per-view optional shortcuts
    @Published private(set) var recentsShortcut: ViewShortcut?
    @Published private(set) var myOrderShortcut: ViewShortcut?
    @Published private(set) var bookmarksShortcut: ViewShortcut?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            "shortcut.keyCode": 49,
            "shortcut.modifiers": Int(NSEvent.ModifierFlags([.command, .shift]).rawValue),
            "shortcut.keyName": "Space"
        ])

        keyCode = UInt16(defaults.integer(forKey: "shortcut.keyCode"))
        modifiers = NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "shortcut.modifiers")))
        keyDisplayName = defaults.string(forKey: "shortcut.keyName") ?? "Space"

        recentsShortcut = Self.loadViewShortcut(prefix: "shortcut.recents", from: defaults)
        myOrderShortcut = Self.loadViewShortcut(prefix: "shortcut.myOrder", from: defaults)
        bookmarksShortcut = Self.loadViewShortcut(prefix: "shortcut.bookmarks", from: defaults)
    }

    func update(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyDisplayName = keyName
        defaults.set(Int(keyCode), forKey: "shortcut.keyCode")
        defaults.set(Int(modifiers.rawValue), forKey: "shortcut.modifiers")
        defaults.set(keyName, forKey: "shortcut.keyName")
    }

    func updateViewShortcut(for view: CommandBarView, shortcut: ViewShortcut?) {
        let prefix: String
        switch view {
        case .recents:
            recentsShortcut = shortcut
            prefix = "shortcut.recents"
        case .myOrder:
            myOrderShortcut = shortcut
            prefix = "shortcut.myOrder"
        case .bookmarks:
            bookmarksShortcut = shortcut
            prefix = "shortcut.bookmarks"
        }

        if let shortcut {
            defaults.set(Int(shortcut.keyCode), forKey: "\(prefix).keyCode")
            defaults.set(Int(shortcut.modifiers), forKey: "\(prefix).modifiers")
            defaults.set(shortcut.keyName, forKey: "\(prefix).keyName")
        } else {
            defaults.removeObject(forKey: "\(prefix).keyCode")
            defaults.removeObject(forKey: "\(prefix).modifiers")
            defaults.removeObject(forKey: "\(prefix).keyName")
        }
    }

    func shortcut(for view: CommandBarView) -> ViewShortcut? {
        switch view {
        case .recents: return recentsShortcut
        case .myOrder: return myOrderShortcut
        case .bookmarks: return bookmarksShortcut
        }
    }

    var allConfiguredModifiers: [NSEvent.ModifierFlags] {
        var list = [modifiers.intersection(.deviceIndependentFlagsMask)]
        if let recents = recentsShortcut {
            list.append(recents.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
        if let myOrder = myOrderShortcut {
            list.append(myOrder.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
        if let bookmarks = bookmarksShortcut {
            list.append(bookmarks.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
        return list
    }

    func isAnyShortcutModifierHeld(in currentFlags: NSEvent.ModifierFlags) -> Bool {
        let masked = currentFlags.intersection(.deviceIndependentFlagsMask)
        guard !masked.isEmpty else { return false }
        return allConfiguredModifiers.contains { !masked.intersection($0).isEmpty }
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

    private static func loadViewShortcut(prefix: String, from defaults: UserDefaults) -> ViewShortcut? {
        guard let keyName = defaults.string(forKey: "\(prefix).keyName"),
              defaults.object(forKey: "\(prefix).keyCode") != nil,
              defaults.object(forKey: "\(prefix).modifiers") != nil else {
            return nil
        }
        let code = UInt16(defaults.integer(forKey: "\(prefix).keyCode"))
        let mods = UInt(defaults.integer(forKey: "\(prefix).modifiers"))
        return ViewShortcut(keyCode: code, modifiers: mods, keyName: keyName)
    }
}
