import AppKit
import Testing
@testable import AgentBar

struct HotkeyChangeOutcomeTests {
    private let previous = AgentHotkeyConfig.standard
    private let requested = AgentHotkeyConfig(keyCode: 49, modifiers: [.command], keyName: "Space")

    @Test func successMakesTheRequestedShortcutActive() {
        let outcome = HotkeyChangeOutcome.resolve(previous: previous, requested: requested, registrationIssue: nil)
        #expect(outcome == .applied(requested))
        #expect(outcome.active == requested)
        #expect(outcome.message == nil)
    }

    @Test func refusalKeepsThePreviousShortcutAndExplainsInPlainEnglish() {
        let outcome = HotkeyChangeOutcome.resolve(
            previous: previous, requested: requested,
            registrationIssue: "Shortcut already registered by AgentBar or another app."
        )
        #expect(outcome.active == previous)
        #expect(outcome.message == "⌘Space can't be used. Shortcut already registered by AgentBar or another app. Still using ⌥Tab.")
    }
}
