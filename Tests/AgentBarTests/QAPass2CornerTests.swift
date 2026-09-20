import Foundation
import Testing
@testable import AgentBar

/// QA pass 2: corner tab edge cases found by review.
struct QAPass2CornerTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let one = CornerTabContent(count: 1, newestName: "one")
    private let timing = CornerTabTiming(visibleSeconds: 5, hoverDwellSeconds: 0.3, leaveGraceSeconds: 0.7)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// The pointer was on the tab when it was clicked (the host stops watching the pointer while the panel is
    /// open, so no "pointer left" ever arrives). The next ordinary arrival must still time out after 5s, not
    /// stay up (or vanish after the leave grace) because of a pointer position from before the panel opened.
    @Test func aPointerPositionFromBeforeThePanelOpenedDoesNotHijackTheNextArrivalTab() {
        var machine = CornerTabMachine(timing: timing)
        _ = machine.handle(.arrival(one), now: at(0))
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(1))
        _ = machine.handle(.tabClicked, now: at(2))
        _ = machine.handle(.panelVisibility(true), now: at(2))
        _ = machine.handle(.panelVisibility(false), now: at(30))
        _ = machine.handle(.arrival(one), now: at(60))
        #expect(machine.nextDeadline == at(65))
    }

    @Test func aHoverThatWasCutShortByAHotkeyPanelDoesNotHijackTheNextArrivalTab() {
        var machine = CornerTabMachine(timing: timing)
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(0))   // dwelling in the corner
        _ = machine.handle(.panelVisibility(true), now: at(0.1))          // hotkey opens the panel
        _ = machine.handle(.panelVisibility(false), now: at(20))
        _ = machine.handle(.arrival(one), now: at(40))
        #expect(machine.nextDeadline == at(45))
    }
}
