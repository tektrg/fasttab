import Foundation
import Testing
import AppKit
import CommandBarKit
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
        #expect(store.shortcut(for: .stack) == nil)

        // Set Stack shortcut: ⌥2
        let stackShortcut = ViewShortcut(keyCode: 19, modifiers: NSEvent.ModifierFlags.option.rawValue, keyName: "2")
        store.updateViewShortcut(for: .stack, shortcut: stackShortcut)

        #expect(store.shortcut(for: .stack)?.keyName == "2")
        #expect(defaults.string(forKey: "shortcut.stack.keyName") == "2")

        // Reload from defaults
        let reloaded = ShortcutStore(defaults: defaults)
        #expect(reloaded.shortcut(for: .stack)?.keyName == "2")
        #expect(reloaded.shortcut(for: .recents) == nil)

        // Clear shortcut
        store.updateViewShortcut(for: .stack, shortcut: nil)
        #expect(store.shortcut(for: .stack) == nil)
        #expect(defaults.object(forKey: "shortcut.stack.keyName") == nil)
    }

    @MainActor
    @Test func legacyMyOrderShortcutMigratesToStack() {
        let suiteName = "test.fasttab.shortcut.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(19, forKey: "shortcut.myOrder.keyCode")
        defaults.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: "shortcut.myOrder.modifiers")
        defaults.set("2", forKey: "shortcut.myOrder.keyName")

        let store = ShortcutStore(defaults: defaults)
        #expect(store.shortcut(for: .stack)?.keyName == "2")
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

        // Add ⌃S for Stack
        let stack = ViewShortcut(keyCode: 1, modifiers: NSEvent.ModifierFlags.control.rawValue, keyName: "S")
        store.updateViewShortcut(for: .stack, shortcut: stack)

        #expect(store.isAnyShortcutModifierHeld(in: [.control]))
    }
}
