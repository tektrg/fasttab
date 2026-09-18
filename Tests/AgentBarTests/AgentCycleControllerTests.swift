import AppKit
import Testing
@testable import AgentBar

@MainActor
struct AgentCycleControllerTests {
    /// A stand-in panel: `rows` selectable rows, wrapping selection like the real one.
    @MainActor private final class FakePanel {
        var isVisible = false
        var rowCount = 3
        var selected: Int?
        var opens = 0
        var commits: [Int?] = []

        func open() {
            isVisible = true
            opens += 1
            selected = rowCount > 0 ? 0 : nil
        }

        func move(_ step: Int) -> Bool {
            guard rowCount > 0 else { return false }
            selected = (((selected ?? 0) + step) % rowCount + rowCount) % rowCount
            return true
        }
    }

    private let held: NSEvent.ModifierFlags = [.option]
    private let released: NSEvent.ModifierFlags = []

    private func makeController(_ panel: FakePanel) -> AgentCycleController {
        AgentCycleController(
            shortcutModifiers: [.option],
            actions: .init(
                isPanelVisible: { panel.isVisible },
                openPanel: { panel.open() },
                moveSelection: { panel.move($0) },
                commitSelection: {
                    panel.commits.append(panel.selected)
                    panel.isVisible = false
                }
            )
        )
    }

    @Test func firstPressOpensWithoutCycling() {
        let panel = FakePanel()
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        #expect(panel.opens == 1)
        #expect(panel.selected == 0)
    }

    @Test func releaseWithoutCyclingLeavesThePanelOpen() {
        let panel = FakePanel()
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.modifiersChanged(released)
        #expect(panel.commits.isEmpty)
        #expect(panel.isVisible)
    }

    @Test func tabsWhileHeldAdvanceAndReleaseCommitsTheSelection() {
        let panel = FakePanel()
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.modifiersChanged(held)          // still holding: no commit
        #expect(panel.commits.isEmpty)
        controller.modifiersChanged(released)
        #expect(panel.commits == [2])
    }

    @Test func backwardStepsWrapFromTheFirstRow() {
        let panel = FakePanel()
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.hotkeyPressed(.backward, currentModifiers: held)
        controller.modifiersChanged(released)
        #expect(panel.commits == [2])
    }

    @Test func plainOpenThenPressAdvancesAndReleaseSwitches() {
        let panel = FakePanel()
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.modifiersChanged(released)                        // plain mode
        controller.hotkeyPressed(.forward, currentModifiers: held)   // modifier down again
        #expect(panel.selected == 1)
        controller.modifiersChanged(released)
        #expect(panel.commits == [1])
    }

    @Test func commitWithNothingSelectableDoesNothing() {
        let panel = FakePanel()
        panel.rowCount = 0
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.modifiersChanged(released)
        #expect(panel.commits.isEmpty)
        #expect(panel.isVisible)
    }

    @Test func aTapThatReleasedBeforeTheHandlerRanOpensPlain() {
        let panel = FakePanel()
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: released)
        controller.modifiersChanged(released)
        #expect(panel.isVisible)
        #expect(panel.commits.isEmpty)
    }

    @Test func closingThePanelForgetsAHalfFinishedCycle() {
        let panel = FakePanel()
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        panel.isVisible = false            // Esc
        controller.panelClosed()
        controller.modifiersChanged(released)
        #expect(panel.commits.isEmpty)
    }

    @Test func otherModifiersDoNotCountAsTheShortcutModifier() {
        let panel = FakePanel()
        let controller = makeController(panel)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.hotkeyPressed(.forward, currentModifiers: held)
        controller.modifiersChanged([.shift])     // ⌥ let go while ⇧ still down
        #expect(panel.commits == [1])
    }
}
