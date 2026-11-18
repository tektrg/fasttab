import SwiftUI
import Testing
import IndieCommandBar
@testable import AgentBar

/// Key hints (2026-11-15): ⌘K in the list footer, Peek's tab keys, a complete Focus footer, and a
/// priority drop instead of a wrap. Renders: `FOCUS_RENDER_DIR=<dir> swift test --filter KeyHintsTests`.
@MainActor @Suite(.serialized)
struct KeyHintsTests {
    typealias F = AgentListFixtures
    typealias H = PanelFooterHints

    // MARK: Priority drop (pure)

    @Test func candidatesDropLowestPriorityFirstKeepingOrder() {
        let lines = KeyHintFit.candidates(["a", "b", "c", "d"]) { ["a": 2, "b": 1, "c": 3, "d": 1][$0]! }
        #expect(lines == [["a", "b", "c", "d"], ["a", "b", "c"], ["a", "c"], ["c"]])   // tie: rightmost goes first
    }

    @Test func emptyAndSingleInputs() {
        #expect(KeyHintFit.candidates([Int]()) { $0 } == [[]])
        #expect(KeyHintFit.candidates([7]) { $0 } == [[7]])
    }

    @Test func listFooterDropsCommandKThenSpaceAndKeepsEscLast() {
        let lines = KeyHintFit.candidates(H.guidance(for: .init()).tokens).map { $0.map(\.glyph) }
        #expect(lines.first == ["↑↓", "←→", "space", "↩", "⌘K", "esc"])
        #expect(lines[1] == ["↑↓", "←→", "↩", "⌘K", "esc"])   // space peek first
        #expect(lines[2] == ["↑↓", "←→", "↩", "esc"])
        #expect(lines.last == ["esc"])
    }

    @Test func focusFooterDropsTickThenGoToThenDigits() {
        let lines = KeyHintFit.candidates(FocusHints.items(goToLabel: "go to agent", hotkey: "⌥⇧F"), priority: \.priority).map { $0.map(\.key) }
        #expect(lines[0] == ["↑ ↓", "1–9", "space", "↩", "⌘← ⌘→", "⌘↩", "esc / ⌥⇧F"])
        #expect(lines[1] == ["↑ ↓", "1–9", "↩", "⌘← ⌘→", "⌘↩", "esc / ⌥⇧F"])
        #expect(lines[2] == ["↑ ↓", "1–9", "↩", "⌘← ⌘→", "esc / ⌥⇧F"])
        #expect(lines.last == ["esc / ⌥⇧F"])
    }

    // MARK: Words

    @Test func listFooterNamesCommandK() {
        #expect(H.text(for: .init()).contains("⌘K more"))
        #expect(H.text(for: .init(searchIsEmpty: false)).contains("⌘K more"))
    }

    @Test func peekFooterNamesTabKeys() {
        #expect(H.text(for: .init(isPeeking: true)) == "←→/tab tabs   ↩ switch   ⌘K more   space/esc back")
        #expect(H.text(for: .init(isPeeking: true, peekInputFocused: true)) == "←→/tab tabs   ↩ send   esc back")
    }

    /// Every key `FocusKey` acts on has a hint.
    @Test func focusFooterCoversFocusKey() {
        let keys = FocusHints.items(goToLabel: "go to agent", hotkey: "⌥⇧F").map(\.key)
        func k(_ code: UInt16, _ chars: String = "", _ mods: NSEvent.ModifierFlags = []) -> FocusKey.Action? {
            FocusKey.action(for: FocusKey(keyCode: code, characters: chars, modifiers: mods), isTyping: false)
        }
        let mapping: [(FocusKey.Action?, String)] = [
            (k(FocusKey.upKeyCode), "↑ ↓"), (k(18, "1"), "1–9"), (k(FocusKey.spaceKeyCode), "space"),
            (k(FocusKey.returnKeyCode), "↩"), (k(FocusKey.leftKeyCode, "", .command), "⌘← ⌘→"),
            (k(FocusKey.returnKeyCode, "", .command), "⌘↩"), (k(FocusKey.escapeKeyCode), "esc / ⌥⇧F"),
        ]
        for (action, key) in mapping {
            #expect(action != nil)
            #expect(keys.contains(key))
        }
    }

    // MARK: Peek arrow routing (pure)

    @Test func arrowsSwitchTabsOnlyWhenFocusedBoxIsEmpty() {
        typealias R = PeekKeyRouting
        #expect(R.action(keyCode: R.leftKeyCode, hasModifiers: false, focusedText: nil) == .select(.lastMessage))
        #expect(R.action(keyCode: R.rightKeyCode, hasModifiers: false, focusedText: nil) == .select(.terminal))
        #expect(R.action(keyCode: R.rightKeyCode, hasModifiers: false, focusedText: "") == .select(.terminal))
        #expect(R.action(keyCode: R.rightKeyCode, hasModifiers: false, focusedText: "hi") == nil)   // caret moves
        #expect(R.action(keyCode: R.leftKeyCode, hasModifiers: true, focusedText: nil) == nil)
        #expect(R.action(keyCode: R.tabKeyCode, hasModifiers: false, focusedText: "hi") == .toggle)   // Tab always
        #expect(R.action(keyCode: R.tabKeyCode, hasModifiers: true, focusedText: nil) == nil)
        #expect(R.action(keyCode: 125, hasModifiers: false, focusedText: nil) == nil)
    }

    @Test func handlePeekKeySelectsTab() {
        let defaults = makeScratchDefaults("key-hints")
        let model = AgentPanelModel(store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults),
                                    loadPeekMessage: { _ in SessionContext(latestMessage: "hi", planFile: nil) }, now: { F.now })
        model.statusSource = MessageFakeSource()
        model.receive(F.snapshot([F.agent("a", section: .working)]))
        model.select(agentID: "a")
        model.togglePeek()
        model.handlePeekKey(.select(.terminal))
        #expect(model.peek?.tab == .terminal)
        model.handlePeekKey(.select(.terminal))
        #expect(model.peek?.tab == .terminal)
        model.handlePeekKey(.toggle)
        #expect(model.peek?.tab == .lastMessage)
    }

    // MARK: Renders (light + dark, incl. narrow)

    @Test func rendersFooters() async {
        let contexts: [(String, H.Context)] = [
            ("list", .init()), ("list-search", .init(searchIsEmpty: false)),
            ("peek", .init(isPeeking: true)), ("peek-input", .init(isPeeking: true, peekInputFocused: true)),
        ]
        for (name, context) in contexts {
            for width in [680.0, 300.0] {
                await renderLightDark(PanelFooterView(notice: nil, hintContext: context, onOpenSettings: {}),
                                      size: CGSize(width: width, height: AgentPanelMetrics.footerHeight), name: "hints-\(name)-\(Int(width))")
            }
        }
        for width in [1400.0, 640.0] {
            await renderLightDark(FocusHintsBar(goToLabel: "go to agent (pauses Focus)", hotkey: "⌥⇧F").background(Color.black.opacity(0.6)),
                                  size: CGSize(width: width, height: 48), name: "hints-focus-\(Int(width))")
        }
    }
}
