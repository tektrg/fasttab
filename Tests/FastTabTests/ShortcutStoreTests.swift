import Foundation
import Testing
import AppKit
@testable import FastTab

struct ShortcutStoreTests {
    @MainActor
    @Test func primaryShortcutPreservesKeys() {
        let suiteName = "test.fasttab.shortcut.primary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ShortcutStore(defaults: defaults)
        #expect(store.keyCode == 49)
        #expect(store.keyDisplayName == "Space")

        store.update(keyCode: 18, modifiers: [.command], keyName: "1")
        #expect(defaults.integer(forKey: "shortcut.keyCode") == 18)
        #expect(defaults.string(forKey: "shortcut.keyName") == "1")
    }

    @MainActor
    @Test func perViewShortcutsPersistenceAndClearing() {
        let suiteName = "test.fasttab.shortcut.views.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ShortcutStore(defaults: defaults)
        #expect(store.shortcut(for: .recents) == nil)
        #expect(store.shortcut(for: .myOrder) == nil)
        #expect(store.shortcut(for: .bookmarks) == nil)

        // Set My Order shortcut: ⌥2
        let myOrderShortcut = ViewShortcut(keyCode: 19, modifiers: NSEvent.ModifierFlags.option.rawValue, keyName: "2")
        store.updateViewShortcut(for: .myOrder, shortcut: myOrderShortcut)

        #expect(store.shortcut(for: .myOrder)?.keyName == "2")
        #expect(defaults.string(forKey: "shortcut.myOrder.keyName") == "2")

        // Reload from defaults
        let reloaded = ShortcutStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .myOrder)?.keyName == "2")
        #expect(reloaded.shortcut(for: .recents) == nil)

        // Clear shortcut
        store.updateViewShortcut(for: .myOrder, shortcut: nil)
        #expect(store.shortcut(for: .myOrder) == nil)
        #expect(defaults.object(forKey: "shortcut.myOrder.keyName") == nil)
    }

    @MainActor
    @Test func modifierHoldingDetection() {
        let suiteName = "test.fasttab.shortcut.mods.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ShortcutStore(defaults: defaults)
        // Primary is ⌘⇧Space
        #expect(store.isAnyShortcutModifierHeld(in: [.command]))
        #expect(store.isAnyShortcutModifierHeld(in: [.shift]))
        #expect(!store.isAnyShortcutModifierHeld(in: [.control]))

        // Add ⌃B for bookmarks
        let bms = ViewShortcut(keyCode: 11, modifiers: NSEvent.ModifierFlags.control.rawValue, keyName: "B")
        store.updateViewShortcut(for: .bookmarks, shortcut: bms)

        #expect(store.isAnyShortcutModifierHeld(in: [.control]))
    }
}
