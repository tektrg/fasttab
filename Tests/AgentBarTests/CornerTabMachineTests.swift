import Foundation
import Testing
@testable import AgentBar

struct CornerTabMachineTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let one = CornerTabContent(count: 1, newestName: "one")
    private let two = CornerTabContent(count: 2, newestName: "two")
    private let timing = CornerTabTiming(visibleSeconds: 5, hoverGraceSeconds: 0.5)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func machine(enabled: Bool = true) -> CornerTabMachine {
        CornerTabMachine(timing: timing, isEnabled: enabled)
    }

    /// A machine showing the tab, with the mouse already seen outside it.
    private func showingTab(mouseHasLeft: Bool = true) -> CornerTabMachine {
        var machine = machine()
        _ = machine.handle(.arrival(one), now: at(0))
        if mouseHasLeft { _ = machine.handle(.mouse(isOverTabOrPanel: false), now: at(0.1)) }
        return machine
    }

    // MARK: - Showing and hiding

    @Test func anArrivalShowsTheTabForTheVisibleTime() {
        var machine = machine()
        #expect(machine.handle(.arrival(one), now: at(0)) == [.showTab(one)])
        #expect(machine.nextDeadline == at(5))
        #expect(machine.wantsMouseUpdates)
        #expect(!machine.wantsKeyPresses)
    }

    @Test func theTabSlidesOutWhenTimeIsUp() {
        var machine = showingTab()
        #expect(machine.handle(.deadlineReached, now: at(4.9)) == [])
        #expect(machine.handle(.deadlineReached, now: at(5)) == [.slideTabOut])
        #expect(machine.phase == .idle)
        #expect(machine.nextDeadline == nil)
        #expect(!machine.wantsMouseUpdates)
    }

    @Test func aSecondArrivalUpdatesAndExtendsTheSameTab() {
        var machine = showingTab()
        #expect(machine.handle(.arrival(two), now: at(3)) == [.updateTab(two)])
        #expect(machine.nextDeadline == at(8))
        #expect(machine.handle(.deadlineReached, now: at(5)) == [])
    }

    @Test func noTabWhileThePanelIsOpen() {
        var machine = machine()
        _ = machine.handle(.panelVisibility(true), now: at(0))
        #expect(machine.handle(.arrival(one), now: at(1)) == [])
        #expect(machine.phase == .idle)
    }

    @Test func noTabWhenTheSettingIsOff() {
        var machine = machine(enabled: false)
        #expect(machine.handle(.arrival(one), now: at(0)) == [])
        _ = machine.handle(.enabled(true), now: at(1))
        #expect(machine.handle(.arrival(one), now: at(2)) == [.showTab(one)])
    }

    @Test func turningTheSettingOffRemovesAShowingTab() {
        var machine = showingTab()
        #expect(machine.handle(.enabled(false), now: at(1)) == [.slideTabOut])
        #expect(machine.phase == .idle)
    }

    @Test func openingThePanelBySomeOtherRouteRemovesTheTab() {
        var machine = showingTab()
        #expect(machine.handle(.panelVisibility(true), now: at(1)) == [.removeTabNow])
        #expect(machine.phase == .idle)
    }

    // MARK: - Hover

    @Test func hoveringTheTabOpensThePanelAndKeepsItOpen() {
        var machine = showingTab()
        #expect(machine.handle(.mouse(isOverTabOrPanel: true), now: at(1)) == [.removeTabNow, .openPanel])
        #expect(machine.phase == .hoverOpen(closeAt: nil))
        #expect(machine.nextDeadline == nil)
        #expect(machine.wantsKeyPresses)
        _ = machine.handle(.panelVisibility(true), now: at(1))
        #expect(machine.phase == .hoverOpen(closeAt: nil))
    }

    @Test func aCursorThatWasAlreadyThereDoesNotOpenThePanel() {
        var machine = showingTab(mouseHasLeft: false)
        #expect(machine.handle(.mouse(isOverTabOrPanel: true), now: at(0.05)) == [])
        #expect(machine.phase == .tab(hideAt: at(5), mouseHasLeft: false))
        // It leaves and comes back: that is a hover.
        _ = machine.handle(.mouse(isOverTabOrPanel: false), now: at(1))
        #expect(machine.handle(.mouse(isOverTabOrPanel: true), now: at(2)) == [.removeTabNow, .openPanel])
    }

    @Test func leavingStartsAGraceAndComingBackCancelsIt() {
        var machine = hoverOpen()
        _ = machine.handle(.mouse(isOverTabOrPanel: false), now: at(10))
        #expect(machine.nextDeadline == at(10.5))
        _ = machine.handle(.mouse(isOverTabOrPanel: true), now: at(10.3))
        #expect(machine.nextDeadline == nil)
        #expect(machine.handle(.deadlineReached, now: at(10.6)) == [])
    }

    @Test func thePanelClosesWhenTheGraceRunsOut() {
        var machine = hoverOpen()
        _ = machine.handle(.mouse(isOverTabOrPanel: false), now: at(10))
        #expect(machine.handle(.deadlineReached, now: at(10.4)) == [])
        #expect(machine.handle(.deadlineReached, now: at(10.5)) == [.closePanel])
        #expect(machine.phase == .idle)
    }

    @Test func repeatedLeaveSamplesDoNotPushTheGraceBack() {
        var machine = hoverOpen()
        _ = machine.handle(.mouse(isOverTabOrPanel: false), now: at(10))
        _ = machine.handle(.mouse(isOverTabOrPanel: false), now: at(10.3))
        #expect(machine.nextDeadline == at(10.5))
    }

    @Test func aKeyPressTurnsItIntoANormallySummonedPanel() {
        var machine = hoverOpen()
        _ = machine.handle(.keyPressed, now: at(11))
        #expect(machine.phase == .idle)
        #expect(machine.nextDeadline == nil)
        #expect(!machine.wantsMouseUpdates)
        #expect(machine.handle(.mouse(isOverTabOrPanel: false), now: at(12)) == [])
    }

    @Test func closingThePanelYourselfEndsTheHoverSession() {
        var machine = hoverOpen()
        _ = machine.handle(.mouse(isOverTabOrPanel: false), now: at(10))
        #expect(machine.handle(.panelVisibility(false), now: at(10.1)) == [])
        #expect(machine.phase == .idle)
        #expect(machine.handle(.deadlineReached, now: at(11)) == [])
    }

    @Test func noArrivalTabWhileAHoverPanelIsOpen() {
        var machine = hoverOpen()
        #expect(machine.handle(.arrival(two), now: at(9)) == [])
    }

    // MARK: - Click

    @Test func clickingTheTabOpensThePanelLikeASummon() {
        var machine = showingTab(mouseHasLeft: false)
        #expect(machine.handle(.tabClicked, now: at(1)) == [.removeTabNow, .openPanel])
        #expect(machine.phase == .idle)
        _ = machine.handle(.panelVisibility(true), now: at(1))
        #expect(machine.handle(.mouse(isOverTabOrPanel: false), now: at(9)) == [])
        #expect(machine.nextDeadline == nil)
    }

    @Test func aClickWithNoTabDoesNothing() {
        var machine = machine()
        #expect(machine.handle(.tabClicked, now: at(0)) == [])
    }

    // MARK: -

    private func hoverOpen() -> CornerTabMachine {
        var machine = showingTab()
        _ = machine.handle(.mouse(isOverTabOrPanel: true), now: at(1))
        _ = machine.handle(.panelVisibility(true), now: at(1))
        return machine
    }
}
