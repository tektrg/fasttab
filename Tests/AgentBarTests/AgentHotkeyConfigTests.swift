import AppKit
import Foundation
import Testing
@testable import AgentBar

struct AgentHotkeyConfigTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.agentbar.hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func configured(keyCode: Any?, modifiers: Any?) -> AgentHotkeyConfig {
        let defaults = makeDefaults()
        if let keyCode { defaults.set(keyCode, forKey: AgentHotkeyConfig.keyCodeDefaultsKey) }
        if let modifiers { defaults.set(modifiers, forKey: AgentHotkeyConfig.modifiersDefaultsKey) }
        return AgentHotkeyConfig.configured(defaults: defaults)
    }

    @Test func defaultsToOptionTab() {
        let config = AgentHotkeyConfig.configured(defaults: makeDefaults())
        #expect(config == .standard)
        #expect(config.keyCode == 48)
        #expect(config.modifiers == [.option])
        #expect(config.displayName == "⌥Tab")
    }

    @Test func readsAConfiguredShortcut() {
        let config = configured(keyCode: 49, modifiers: 3)   // ⌘⌥Space
        #expect(config.keyCode == 49)
        #expect(config.modifiers == [.command, .option])
    }

    @Test func fallsBackWhenOnlyOneKeyIsPresent() {
        #expect(configured(keyCode: 49, modifiers: nil) == .standard)
        #expect(configured(keyCode: nil, modifiers: 2) == .standard)
    }

    @Test func fallsBackOnInvalidValues() {
        #expect(configured(keyCode: 49, modifiers: 0) == .standard)      // a bare key would steal it everywhere
        #expect(configured(keyCode: 49, modifiers: 16) == .standard)     // unknown modifier bit
        #expect(configured(keyCode: 49, modifiers: -2) == .standard)
        #expect(configured(keyCode: 500, modifiers: 2) == .standard)     // not a virtual key code
        #expect(configured(keyCode: -1, modifiers: 2) == .standard)
        #expect(configured(keyCode: "tab", modifiers: 2) == .standard)   // wrong type
    }

    @Test func keyCodeZeroIsAValidKey() {
        #expect(configured(keyCode: 0, modifiers: 2).keyCode == 0)
    }

    @Test func backwardShortcutAddsShift() {
        #expect(AgentHotkeyConfig.standard.backwardModifiers == [.option, .shift])
    }

    @Test func backwardShortcutIsSkippedWhenShiftIsAlreadyInTheMainOne() {
        let config = configured(keyCode: 48, modifiers: 10)   // ⌥⇧Tab
        #expect(config.modifiers == [.option, .shift])
        #expect(config.backwardModifiers == nil)
    }

    // MARK: - Settings UI support

    @Test func aRecordedShortcutNeedsAModifier() {
        #expect(AgentHotkeyConfig.recorded(keyCode: 49, modifiers: [], keyName: "Space") == nil)
        #expect(AgentHotkeyConfig.recorded(keyCode: 49, modifiers: [.capsLock], keyName: "Space") == nil)
        let config = AgentHotkeyConfig.recorded(keyCode: 49, modifiers: [.control, .shift], keyName: "Space")
        #expect(config?.modifiers == [.control, .shift])
        #expect(config?.displayName == "⌃⇧Space")
    }

    @Test func aRecordedShortcutIgnoresIrrelevantModifierBits() {
        let flags: NSEvent.ModifierFlags = [.option, .function, .capsLock]
        #expect(AgentHotkeyConfig.recorded(keyCode: 48, modifiers: flags, keyName: "Tab") == .standard)
    }

    @Test func aSavedShortcutRoundTripsWithItsKeyName() {
        let defaults = makeDefaults()
        AgentHotkeyConfig(keyCode: 40, modifiers: [.command, .control], keyName: "K").save(to: defaults)
        let loaded = AgentHotkeyConfig.configured(defaults: defaults)
        #expect(loaded.keyCode == 40)
        #expect(loaded.modifiers == [.command, .control])
        #expect(loaded.displayName == "⌃⌘K")
    }

    @Test func savingTheStandardShortcutClearsTheOverride() {
        let defaults = makeDefaults()
        AgentHotkeyConfig(keyCode: 49, modifiers: [.command], keyName: "Space").save(to: defaults)
        AgentHotkeyConfig.standard.save(to: defaults)
        for key in [AgentHotkeyConfig.keyCodeDefaultsKey, AgentHotkeyConfig.modifiersDefaultsKey, AgentHotkeyConfig.keyNameDefaultsKey] {
            #expect(defaults.object(forKey: key) == nil)
        }
        #expect(AgentHotkeyConfig.configured(defaults: defaults) == .standard)
    }

    @Test func aShortcutSetWithDefaultsWriteIsNamedFromItsKeyCode() {
        #expect(configured(keyCode: 49, modifiers: 3).displayName == "⌥⌘Space")
        #expect(AgentHotkeyConfig(keyCode: 127, modifiers: [.option]).displayName == "⌥key 127")
    }

    @Test func theSameKeysAreTheSameShortcutWhateverTheyAreCalled() {
        #expect(AgentHotkeyConfig(keyCode: 48, modifiers: [.option], keyName: "⇥") == .standard)
    }

    @Test func backwardShortcutIsShownOrExplainedAsUnavailable() {
        #expect(AgentHotkeyConfig.standard.backwardDisplayName == "⌥⇧Tab")
        #expect(AgentHotkeyConfig(keyCode: 49, modifiers: [.control, .command], keyName: "Space").backwardDisplayName == "⌃⇧⌘Space")
        #expect(AgentHotkeyConfig(keyCode: 48, modifiers: [.option, .shift]).backwardDisplayName == nil)
    }
}
