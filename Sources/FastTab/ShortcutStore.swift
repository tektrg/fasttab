import AppKit
import Combine
import CommandBarKit

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
        ViewShortcut.modifierSymbols(for: modifiers)
    }

    var displayString: String {
        modifierSymbols + keyDisplayName
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
