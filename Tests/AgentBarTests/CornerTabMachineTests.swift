import Foundation
import Testing
@testable import AgentBar

struct CornerTabMachineTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let one = CornerTabContent(count: 1, newestName: "one")
    private let two = CornerTabContent(count: 2, newestName: "two")
    private let timing = CornerTabTiming(visibleSeconds: 5, hoverDwellSeconds: 0.3, leaveGraceSeconds: 0.7)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func machine(enabled: Bool = true) -> CornerTabMachine {
        CornerTabMachine(timing: timing, isEnabled: enabled)
    }

    /// A machine showing an arrival's tab, the pointer elsewhere.
    private func showingArrivalTab() -> CornerTabMachine {
        var machine = machine()
        _ = machine.handle(.arrival(one), now: at(0))
        return machine
    }

    /// A machine whose pointer rested in the corner and brought the tab in at 0.3s.
    private func showingHoverTab() -> CornerTabMachine {
        var machine = machine()
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(0))
        _ = machine.handle(.deadlineReached, now: at(0.3))
        return machine
    }

    // MARK: - An agent arrives

    @Test func anArrivalShowsTheTabForTheVisibleTime() {
        var machine = machine()
        #expect(machine.handle(.arrival(one), now: at(0)) == [.showTab(one)])
        #expect(machine.nextDeadline == at(5))
        #expect(machine.wantsMousePolling)
    }

    @Test func theArrivalTabSlidesOutWhenTimeIsUp() {
        var machine = showingArrivalTab()
        #expect(machine.handle(.deadlineReached, now: at(4.9)) == [])
        #expect(machine.handle(.deadlineReached, now: at(5)) == [.slideTabOut])
        #expect(machine.phase == .idle)
        #expect(machine.nextDeadline == nil)
        #expect(!machine.wantsMousePolling)
    }

    @Test func aSecondArrivalUpdatesAndExtendsTheSameTab() {
        var machine = showingArrivalTab()
        #expect(machine.handle(.arrival(two), now: at(3)) == [.updateTab(two)])
        #expect(machine.nextDeadline == at(8))
        #expect(machine.handle(.deadlineReached, now: at(5)) == [])
    }

    @Test func theArrivalTabStaysWhileThePointerIsOnItAndLeavesAfterAGrace() {
        var machine = showingArrivalTab()
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(4))
        #expect(machine.nextDeadline == nil)
        #expect(machine.handle(.deadlineReached, now: at(9)) == [])
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(10))
        #expect(machine.nextDeadline == at(10.7))
        #expect(machine.handle(.deadlineReached, now: at(10.7)) == [.slideTabOut])
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
        var machine = showingArrivalTab()
        #expect(machine.handle(.enabled(false), now: at(1)) == [.slideTabOut])
        #expect(machine.phase == .idle)
    }

    @Test func openingThePanelBySomeOtherRouteRemovesTheTab() {
        var machine = showingArrivalTab()
        #expect(machine.handle(.panelVisibility(true), now: at(1)) == [.removeTabNow])
        #expect(machine.phase == .idle)
    }

    // MARK: - Hovering the corner (any time)

    @Test func restingInTheCornerBringsTheSummaryTabInAfterTheDwell() {
        var machine = machine()
        #expect(machine.handle(.mouse(isOverCornerOrTab: true), now: at(0)) == [])
        #expect(machine.phase == .dwelling(showAt: at(0.3)))
        #expect(machine.nextDeadline == at(0.3))
        #expect(machine.wantsCornerWatch)
        #expect(machine.handle(.deadlineReached, now: at(0.29)) == [])
        #expect(machine.handle(.deadlineReached, now: at(0.3)) == [.showSummaryTab])
        #expect(machine.phase == .tab(hideAt: nil))   // the pointer is still in the corner
    }

    @Test func passingThroughTheCornerShowsNothing() {
        var machine = machine()
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(0))
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(0.1))
        #expect(machine.phase == .idle)
        #expect(machine.nextDeadline == nil)
        #expect(machine.handle(.deadlineReached, now: at(0.3)) == [])
    }

    @Test func theHoverTabHidesAShortWhileAfterThePointerLeaves() {
        var machine = showingHoverTab()
        #expect(machine.nextDeadline == nil)
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(2))
        #expect(machine.nextDeadline == at(2.7))
        // Coming back (onto the tab, say) cancels the hide; leaving again restarts it.
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(2.4))
        #expect(machine.nextDeadline == nil)
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(3))
        #expect(machine.handle(.deadlineReached, now: at(3.7)) == [.slideTabOut])
        #expect(machine.phase == .idle)
    }

    @Test func repeatedLeaveSamplesDoNotPushTheHideBack() {
        var machine = showingHoverTab()
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(2))
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(2.4))
        #expect(machine.nextDeadline == at(2.7))
    }

    @Test func hoveringNeverOpensThePanel() {
        var machine = showingArrivalTab()
        for seconds in [0.5, 1, 2] {
            #expect(machine.handle(.mouse(isOverCornerOrTab: true), now: at(seconds)) == [])
            #expect(machine.handle(.mouse(isOverCornerOrTab: false), now: at(seconds + 0.1)) == [])
        }
        var hovered = showingHoverTab()
        #expect(hovered.handle(.deadlineReached, now: at(10)) == [])
    }

    @Test func anArrivalWhileTheHoverTabIsUpJustUpdatesIt() {
        var machine = showingHoverTab()
        #expect(machine.handle(.arrival(two), now: at(1)) == [.updateTab(two)])
        #expect(machine.phase == .tab(hideAt: nil))   // still hovered: stays
    }

    @Test func anArrivalWhileThePointerDwellsInTheCornerShowsTheTabAtOnce() {
        var machine = machine()
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(0))
        #expect(machine.handle(.arrival(one), now: at(0.1)) == [.showTab(one)])
        #expect(machine.phase == .tab(hideAt: nil))
        #expect(machine.handle(.deadlineReached, now: at(0.3)) == [])
    }

    // MARK: - Off

    @Test func theHotZoneIsOffWhenTheSettingIsOff() {
        var machine = machine(enabled: false)
        #expect(!machine.wantsCornerWatch)
        #expect(machine.handle(.mouse(isOverCornerOrTab: true), now: at(0)) == [])
        #expect(machine.phase == .idle)
        #expect(machine.nextDeadline == nil)
    }

    @Test func turningTheSettingOffDuringTheDwellCancelsIt() {
        var machine = machine()
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(0))
        #expect(machine.handle(.enabled(false), now: at(0.1)) == [])
        #expect(machine.phase == .idle)
        #expect(!machine.wantsCornerWatch)
        #expect(machine.handle(.deadlineReached, now: at(0.3)) == [])
    }

    @Test func theHotZoneIsOffWhileThePanelIsOpen() {
        var machine = machine()
        _ = machine.handle(.panelVisibility(true), now: at(0))
        #expect(!machine.wantsCornerWatch)
        #expect(machine.handle(.mouse(isOverCornerOrTab: true), now: at(1)) == [])
        #expect(machine.phase == .idle)
        _ = machine.handle(.panelVisibility(false), now: at(2))
        #expect(machine.wantsCornerWatch)
    }

    @Test func openingThePanelDuringTheDwellOrOverTheHoverTabEndsIt() {
        var dwelling = machine()
        _ = dwelling.handle(.mouse(isOverCornerOrTab: true), now: at(0))
        #expect(dwelling.handle(.panelVisibility(true), now: at(0.1)) == [])
        #expect(dwelling.phase == .idle)
        var hovering = showingHoverTab()
        #expect(hovering.handle(.panelVisibility(true), now: at(1)) == [.removeTabNow])
        #expect(hovering.phase == .idle)
    }

    // MARK: - Click

    @Test func clickingTheTabOpensThePanelLikeASummon() {
        for var machine in [showingArrivalTab(), showingHoverTab()] {
            #expect(machine.handle(.tabClicked, now: at(1)) == [.removeTabNow, .openPanel])
            #expect(machine.phase == .idle)
            _ = machine.handle(.panelVisibility(true), now: at(1))
            #expect(machine.handle(.mouse(isOverCornerOrTab: false), now: at(9)) == [])
            #expect(machine.nextDeadline == nil)
        }
    }

    @Test func aClickWithNoTabDoesNothing() {
        var machine = machine()
        #expect(machine.handle(.tabClicked, now: at(0)) == [])
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(0))
        #expect(machine.handle(.tabClicked, now: at(0.1)) == [])   // still only dwelling
    }

    // MARK: - Sticky while an agent is blocked on the user

    private let blockedOne = CornerTabContent(count: 1, newestName: "one", blockedCount: 1)
    private let none = CornerTabContent.nothingNeedsYou

    /// A machine showing a tab that arrived already blocked, the pointer elsewhere.
    private func showingBlockedTab() -> CornerTabMachine {
        var machine = machine()
        _ = machine.handle(.arrival(blockedOne), now: at(0))
        return machine
    }

    @Test func aBlockedArrivalTabHasNoTimer() {
        var machine = machine()
        #expect(machine.handle(.arrival(blockedOne), now: at(0)) == [.showTab(blockedOne)])
        #expect(machine.nextDeadline == nil)
        #expect(machine.handle(.deadlineReached, now: at(60)) == [])
        #expect(machine.wantsMousePolling)
    }

    @Test func aBlockedTabStaysAfterThePointerLeavesToo() {
        var machine = showingBlockedTab()
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(1))
        #expect(machine.handle(.mouse(isOverCornerOrTab: false), now: at(2)) == [])
        #expect(machine.nextDeadline == nil)
        #expect(machine.handle(.deadlineReached, now: at(30)) == [])
    }

    @Test func aBlockedTabUpdatesItsCountLive() {
        var machine = showingBlockedTab()
        let three = CornerTabContent(count: 3, newestName: "x", blockedCount: 2)
        #expect(machine.handle(.needsYouChanged(three, hasNewBlocker: false), now: at(1)) == [.updateTab(three)])
        #expect(machine.handle(.needsYouChanged(three, hasNewBlocker: false), now: at(2)) == [])   // unchanged
        #expect(machine.nextDeadline == nil)
    }

    @Test func theTabLeavesAfterTheGraceOnceNoAgentIsBlocked() {
        var machine = showingBlockedTab()
        let generic = CornerTabContent(count: 2, newestName: "two")
        #expect(machine.handle(.needsYouChanged(generic, hasNewBlocker: false), now: at(10)) == [.updateTab(generic)])
        #expect(machine.nextDeadline == at(10.7))
        #expect(machine.handle(.deadlineReached, now: at(10.7)) == [.slideTabOut])
        #expect(machine.phase == .idle)
    }

    @Test func theTabWithThePointerOnItWaitsForThePointerToLeaveWhenTheBlockerGoes() {
        var machine = showingBlockedTab()
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(1))
        _ = machine.handle(.needsYouChanged(none, hasNewBlocker: false), now: at(2))
        #expect(machine.nextDeadline == nil)
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(3))
        #expect(machine.nextDeadline == at(3.7))
    }

    @Test func aGenericTabIsUntouchedByReadingsWithNoBlocker() {
        var machine = showingArrivalTab()
        #expect(machine.handle(.needsYouChanged(two, hasNewBlocker: false), now: at(1)) == [])
        #expect(machine.nextDeadline == at(5))
    }

    @Test func aShowingGenericTabBecomesStickyWhenItsAgentTurnsOutBlocked() {
        var machine = showingArrivalTab()
        #expect(machine.nextDeadline == at(5))
        #expect(machine.handle(.needsYouChanged(blockedOne, hasNewBlocker: true), now: at(2)) == [.updateTab(blockedOne)])
        #expect(machine.nextDeadline == nil)
        #expect(machine.handle(.deadlineReached, now: at(9)) == [])
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(9))
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(10))
        #expect(machine.nextDeadline == nil)
    }

    @Test func aTabThatAlreadySlidOutComesBackStickyWhenABlockerIsLearned() {
        var machine = showingArrivalTab()
        _ = machine.handle(.deadlineReached, now: at(5))
        #expect(machine.phase == .idle)
        #expect(machine.handle(.needsYouChanged(blockedOne, hasNewBlocker: true), now: at(8)) == [.showTab(blockedOne)])
        #expect(machine.nextDeadline == nil)
    }

    @Test func theSameBlockerDoesNotBringTheTabBackAfterItWasClicked() {
        var machine = showingBlockedTab()
        _ = machine.handle(.tabClicked, now: at(1))
        _ = machine.handle(.panelVisibility(true), now: at(1))
        _ = machine.handle(.panelVisibility(false), now: at(5))
        #expect(machine.handle(.needsYouChanged(blockedOne, hasNewBlocker: false), now: at(6)) == [])
        #expect(machine.phase == .idle)
    }

    @Test func aBlockerLearnedWhilePanelIsOpenOrSettingOffShowsNothing() {
        var machine = machine()
        _ = machine.handle(.panelVisibility(true), now: at(0))
        #expect(machine.handle(.needsYouChanged(blockedOne, hasNewBlocker: true), now: at(1)) == [])
        var off = self.machine(enabled: false)
        #expect(off.handle(.needsYouChanged(blockedOne, hasNewBlocker: true), now: at(1)) == [])
    }

    @Test func aBlockedTabEndsWhenThePanelOpensOrTheSettingGoesOff() {
        var opened = showingBlockedTab()
        #expect(opened.handle(.panelVisibility(true), now: at(1)) == [.removeTabNow])
        var off = showingBlockedTab()
        #expect(off.handle(.enabled(false), now: at(1)) == [.slideTabOut])
    }

    @Test func aHoverTabIsStickyWhenAnAgentIsBlocked() {
        var machine = machine()
        _ = machine.handle(.needsYouChanged(blockedOne, hasNewBlocker: false), now: at(0))   // baseline: no tab
        #expect(machine.phase == .idle)
        _ = machine.handle(.mouse(isOverCornerOrTab: true), now: at(1))
        #expect(machine.handle(.deadlineReached, now: at(1.3)) == [.showSummaryTab])
        _ = machine.handle(.mouse(isOverCornerOrTab: false), now: at(2))
        #expect(machine.nextDeadline == nil)
    }

    @Test func aDeadFeedEndsStickiness() {
        var machine = showingBlockedTab()
        _ = machine.handle(.needsYouChanged(none, hasNewBlocker: false), now: at(3))
        #expect(machine.nextDeadline == at(3.7))
    }
}

struct BlockedEpisodeTrackerTests {
    typealias A = AnswerFixtures
    private func seen(_ tracker: inout BlockedEpisodeTracker, _ rows: [AgentSnapshot]?) -> Bool { tracker.observe(rows) }
    private func row(_ id: String, blocked: Bool) -> AgentSnapshot { A.blockedAgent(id, blocker: blocked ? .permission : nil) }

    @Test func theBaselineIsNotNewAndALaterBlockerIs() {
        var tracker = BlockedEpisodeTracker()
        #expect(seen(&tracker, [row("a", blocked: true), row("b", blocked: false)]) == false)
        #expect(seen(&tracker, [row("a", blocked: true), row("b", blocked: false)]) == false)
        #expect(seen(&tracker, [row("a", blocked: true), row("b", blocked: true)]) == true)
        #expect(seen(&tracker, [row("a", blocked: true), row("b", blocked: true)]) == false)
    }

    @Test func oneReportPerStayEvenIfTheBlockerFlaps() {
        var tracker = BlockedEpisodeTracker()
        _ = seen(&tracker, [row("a", blocked: false)])
        #expect(seen(&tracker, [row("a", blocked: true)]) == true)
        #expect(seen(&tracker, [row("a", blocked: false)]) == false)
        #expect(seen(&tracker, [row("a", blocked: true)]) == false)
    }

    @Test func anAgentThatLeftAndCameBackBlockedIsNewAgain() {
        var tracker = BlockedEpisodeTracker()
        _ = seen(&tracker, [row("a", blocked: true)])
        _ = seen(&tracker, [])
        #expect(seen(&tracker, [row("a", blocked: true)]) == true)
    }

    @Test func aDeadFeedRestartsFromABaseline() {
        var tracker = BlockedEpisodeTracker()
        _ = seen(&tracker, [row("a", blocked: false)])
        #expect(seen(&tracker, nil) == false)
        #expect(seen(&tracker, [row("a", blocked: true)]) == false)
    }
}

struct BlockedCornerTabContentTests {
    typealias A = AnswerFixtures

    @Test func countsBlockedAgentsAndSaysSo() {
        let rows = [A.blockedAgent("a", blocker: .permission), A.blockedAgent("b", blocker: nil)]
        let content = CornerTabContent.summary(of: rows)
        #expect(content.count == 2)
        #expect(content.blockedCount == 1)
        #expect(content.headline == "2 need you")
        #expect(content.detail == "waiting for your answer")
        let generic = CornerTabContent.summary(of: [rows[1]])
        #expect(generic.blockedCount == 0)
        #expect(generic.detail == "agent b")
    }
}
