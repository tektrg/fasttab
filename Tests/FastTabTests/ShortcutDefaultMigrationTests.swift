import Foundation
import Testing
import AppKit
import IndieCommandBar
@testable import FastTab

/// Owner decision 2026-11-14: new installs summon Fast Tab with ⌃Tab (⌘⇧Space has no ⇧ twin
/// for going back). Existing installs keep what they use — including people who never
/// changed it and so rely on the old *registered* (never stored) ⌘⇧Space default.
@MainActor
struct ShortcutDefaultMigrationTests {
    let suiteName = "test.fasttab.shortcut.default.\(UUID().uuidString)"

    func scratch() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }

    /// A second handle on the same suite with no registration domain: only stored values show.
    func stored() -> UserDefaults { UserDefaults(suiteName: suiteName)! }

    func cleanUp() { UserDefaults().removePersistentDomain(forName: suiteName) }

    @Test func freshInstallGetsControlTab() {
        defer { cleanUp() }
        let store = ShortcutStore(defaults: scratch())
        #expect(store.keyCode == 48)
        #expect(store.modifiers == [.control])
        #expect(store.keyDisplayName == "⇥")
        #expect(store.displayString == "⌃⇥")
        #expect(store.heroKeycaps == ["⌃", "⇥"])
        // Persisted, so finishing onboarding later cannot flip it to the existing-install default.
        #expect(stored().object(forKey: "shortcut.keyCode") as? Int == 48)
    }

    @Test func freshInstallKeepsControlTabAfterOnboardingCompletes() {
        defer { cleanUp() }
        _ = ShortcutStore(defaults: scratch())
        stored().set(true, forKey: "onboarding.v1.completed")
        let relaunched = ShortcutStore(defaults: stored())
        #expect(relaunched.keyCode == 48)
        #expect(relaunched.modifiers == [.control])
    }

    @Test func existingInstallOnTheUnstoredDefaultKeepsCommandShiftSpace() {
        defer { cleanUp() }
        let defaults = scratch()
        defaults.set(true, forKey: "onboarding.v1.completed")
        let store = ShortcutStore(defaults: defaults)
        #expect(store.keyCode == 49)
        #expect(store.modifiers == [.command, .shift])
        #expect(store.keyDisplayName == "Space")
        #expect(store.displayString == "⇧⌘Space")
        let persisted = stored()
        #expect(persisted.object(forKey: "shortcut.keyCode") as? Int == 49)
        #expect(persisted.object(forKey: "shortcut.modifiers") as? Int == Int(NSEvent.ModifierFlags([.command, .shift]).rawValue))
        #expect(persisted.string(forKey: "shortcut.keyName") == "Space")
    }

    @Test(arguments: [true, false])
    func explicitlyStoredShortcutIsUntouched(onboarded: Bool) {
        defer { cleanUp() }
        let defaults = scratch()
        defaults.set(onboarded, forKey: "onboarding.v1.completed")
        defaults.set(12, forKey: "shortcut.keyCode")
        defaults.set(Int(NSEvent.ModifierFlags.option.rawValue), forKey: "shortcut.modifiers")
        defaults.set("Q", forKey: "shortcut.keyName")
        let store = ShortcutStore(defaults: defaults)
        #expect(store.keyCode == 12)
        #expect(store.modifiers == [.option])
        #expect(store.displayString == "⌥Q")
    }

    @Test func recordingAShortcutAfterMigrationStillWins() {
        defer { cleanUp() }
        let store = ShortcutStore(defaults: scratch())
        store.update(keyCode: 12, modifiers: [.option], keyName: "Q")
        let relaunched = ShortcutStore(defaults: stored())
        #expect(relaunched.keyCode == 12)
        #expect(relaunched.modifiers == [.option])
    }
}

/// The Settings / onboarding recorder must take Tab combos (⌃Tab, ⌃⇧Tab), not lose them to
/// focus navigation, and still ignore modifier-less keys.
struct ShortcutRecorderOutcomeTests {
    typealias R = ShortcutRecorderView

    @Test func controlTabRecords() {
        #expect(R.outcome(keyCode: 48, modifiers: [.control], characters: "\t") == .record(48, [.control], "⇥"))
    }

    @Test func controlShiftTabRecords() {
        #expect(R.outcome(keyCode: 48, modifiers: [.control, .shift], characters: "\t") == .record(48, [.control, .shift], "⇥"))
    }

    @Test func optionQRecords() {
        #expect(R.outcome(keyCode: 12, modifiers: [.option], characters: "q") == .record(12, [.option], "Q"))
    }

    @Test func plainTabIsIgnoredAndEscCancels() {
        #expect(R.outcome(keyCode: 48, modifiers: [], characters: "\t") == .ignore)
        #expect(R.outcome(keyCode: 53, modifiers: [], characters: "\u{1b}") == .cancel)
    }

    @Test func deviceDependentFlagBitsAreDropped() {
        // Real events carry extra bits (e.g. caps lock / device side); only ⌘⇧⌥⌃ are kept.
        let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x1)
        #expect(R.outcome(keyCode: 48, modifiers: flags, characters: "\t") == .record(48, [.control], "⇥"))
    }
}
