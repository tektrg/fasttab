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
}
