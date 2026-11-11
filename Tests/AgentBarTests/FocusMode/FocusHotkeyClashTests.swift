import AppKit
import Testing
@testable import AgentBar

/// Focus mode's shortcut must never take the summon shortcut or its ⇧ backward twin.
struct FocusHotkeyClashTests {
    private let summonOptionF = AgentHotkeyConfig(keyCode: 3, modifiers: [.option], keyName: "F")

    @Test func defaultsDoNotClash() {
        #expect(FocusHotkey.clashMessage(focus: FocusHotkey.standard, summon: .standard) == nil)
    }

    @Test func sameAsSummonClashes() {
        #expect(FocusHotkey.clashMessage(focus: .standard, summon: .standard) != nil)
    }

    @Test func sameAsSummonBackwardTwinClashes() {
        // Summon ⌥F cycles backward on ⌥⇧F, Focus mode's default.
        #expect(FocusHotkey.clashMessage(focus: FocusHotkey.standard, summon: summonOptionF) != nil)
    }

    @Test func clashKeepsPrevious() {
        let outcome = FocusHotkey.resolveChange(previous: FocusHotkey.standard, requested: .standard, summon: .standard)
        #expect(outcome?.active == FocusHotkey.standard)
        #expect(outcome?.message != nil)
    }
}
