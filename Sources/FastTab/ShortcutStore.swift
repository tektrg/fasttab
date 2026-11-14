import AppKit
import Combine
import IndieCommandBar

@MainActor
class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    // Primary / default view shortcut (keys: shortcut.keyCode, shortcut.modifiers, shortcut.keyName)
    @Published private(set) var keyCode: UInt16
    @Published private(set) var modifiers: NSEvent.ModifierFlags
    @Published private(set) var keyDisplayName: String

    // Per-view optional shortcuts
    @Published private(set) var recentsShortcut: ViewShortcut?
    @Published private(set) var stackShortcut: ViewShortcut?

    private let defaults: UserDefaults

    /// The summon shortcut a new install gets: ⌃Tab (owner decision 2026-11-14). Its ⇧ twin
    /// (⌃⇧Tab) steps back while the bar is open, which ⌘⇧Space could never offer.
    static let newInstallDefault = ViewShortcut(
        keyCode: 48, modifiers: NSEvent.ModifierFlags.control.rawValue, keyName: ViewShortcut.keyName(keyCode: 48, characters: nil)
    )
    /// The default every build before 2026-11-14 registered (never stored): ⌘⇧Space.
    static let legacyDefault = ViewShortcut(
        keyCode: 49, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, keyName: "Space"
    )
    /// Written when onboarding finishes, by every build since onboarding shipped (May 2026) —
    /// the same "existing user" signal `EdgeRevealStore` and `CommandBarViewStore` use.
    static let onboardingCompletedKey = "onboarding.v1.completed"
    /// Written on first launch by every build up to 1.3 (`LaunchAtLoginService` started with the
    /// app then; now it starts only with Settings › General, after this pin has run). Catches
    /// installs from before onboarding (they may never have finished it). A 1.4+ install whose
    /// onboarding was never finished counts only if Settings › General was opened.
    static let launchAtLoginInitializedKey = "launchAtLogin.didInitialize"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // No `register(defaults:)` for these keys: the registration domain is process-wide and
        // would make `pinDefaultShortcut` see a value that was never stored. It always stores
        // one, so the fallbacks below are only a safety net.
        Self.pinDefaultShortcut(in: defaults)
        let fallback = Self.newInstallDefault
        keyCode = (defaults.object(forKey: "shortcut.keyCode") as? Int).map { UInt16($0) } ?? fallback.keyCode
        modifiers = NSEvent.ModifierFlags(rawValue: (defaults.object(forKey: "shortcut.modifiers") as? Int).map { UInt($0) } ?? fallback.modifiers)
        keyDisplayName = defaults.string(forKey: "shortcut.keyName") ?? fallback.keyName

        recentsShortcut = Self.loadViewShortcut(prefix: "shortcut.recents", from: defaults)
        stackShortcut = Self.loadViewShortcut(prefix: "shortcut.stack", from: defaults)
            ?? Self.loadViewShortcut(prefix: "shortcut.myOrder", from: defaults)
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
        case .stack:
            stackShortcut = shortcut
            prefix = "shortcut.stack"
        case .custom, .newView:
            // Global shortcuts exist for the builtin views only.
            return
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
        case .stack: return stackShortcut
        case .custom, .newView: return nil
        }
    }

    var allConfiguredModifiers: [NSEvent.ModifierFlags] {
        var list = [modifiers.intersection(.deviceIndependentFlagsMask)]
        if let recents = recentsShortcut {
            list.append(recents.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
        if let stack = stackShortcut {
            list.append(stack.modifierFlags.intersection(.deviceIndependentFlagsMask))
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

    /// One-time: an install with no stored summon shortcut gets one written down, so changing the new-install default never moves anyone.
    /// Onboarding already finished, or a pre-onboarding build ran here (`launchAtLoginInitializedKey`)
    /// → this Mac used the old unstored ⌘⇧Space, keep it. Otherwise
    /// it is a fresh install → ⌃Tab, stored now so finishing onboarding later cannot flip it.
    /// A shortcut the user recorded is stored already and untouched. Nothing may
    /// `register(defaults:)` these keys: `object(forKey:)` would see the registered value.
    static func pinDefaultShortcut(in defaults: UserDefaults) {
        guard defaults.object(forKey: "shortcut.keyCode") == nil else { return }
        let isExistingInstall = defaults.bool(forKey: onboardingCompletedKey)
            || defaults.object(forKey: launchAtLoginInitializedKey) != nil
        let pinned = isExistingInstall ? legacyDefault : newInstallDefault
        defaults.set(Int(pinned.keyCode), forKey: "shortcut.keyCode")
        defaults.set(Int(pinned.modifiers), forKey: "shortcut.modifiers")
        defaults.set(pinned.keyName, forKey: "shortcut.keyName")
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
