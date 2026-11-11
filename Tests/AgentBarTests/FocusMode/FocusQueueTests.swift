import Foundation
import Testing
@testable import AgentBar

struct FocusQueueTests {
    @Test func startsOnFirstInListOrder() {
        let queue = FocusQueue(listOrder: ["a", "b", "c"])
        #expect(queue.currentID == "a")
        #expect(queue.position == 1)
        #expect(queue.count == 3)
    }

    @Test func emptyIsAllClear() {
        let queue = FocusQueue(listOrder: [])
        #expect(queue.isAllClear)
        #expect(queue.currentID == nil)
        #expect(queue.position == nil)
    }

    @Test func nextAndPreviousDoNotWrap() {
        var queue = FocusQueue(listOrder: ["a", "b"])
        let moved1 = queue.moveBack()
        #expect(!moved1)
        let moved2 = queue.moveForward()
        #expect(moved2)
        #expect(queue.currentID == "b")
        let moved3 = queue.moveForward()
        #expect(!moved3)
        #expect(queue.currentID == "b")
        let moved4 = queue.moveBack()
        #expect(moved4)
        #expect(queue.currentID == "a")
    }

    @Test func singleAgentArrowsAreInert() {
        var queue = FocusQueue(listOrder: ["a"])
        #expect(!queue.canMoveBack && !queue.canMoveForward)
        let moved5 = queue.moveForward()
        #expect(!moved5)
        #expect(queue.currentID == "a")
    }

    @Test func answeredAgentAdvancesToNextKeepingPosition() {
        var queue = FocusQueue(listOrder: ["a", "b", "c"])
        queue.moveForward()
        queue.markHandled("b")
        #expect(queue.currentID == "c")
        #expect(queue.position == 2)
    }

    @Test func answeredLastGoesToPrevious() {
        var queue = FocusQueue(listOrder: ["a", "b"])
        queue.moveForward()
        queue.markHandled("b")
        #expect(queue.currentID == "a")
    }

    @Test func answeredOnlyOneIsAllClear() {
        var queue = FocusQueue(listOrder: ["a"])
        queue.markHandled("a")
        #expect(queue.isAllClear)
    }

    @Test func handledStaysOutWhileDashboardLags() {
        var queue = FocusQueue(listOrder: ["a", "b"])
        queue.markHandled("a")
        queue.update(listOrder: ["a", "b"])
        #expect(queue.agentIDs == ["b"])
        // Leaves the list, then needs you again later: back in.
        queue.update(listOrder: ["b"])
        queue.update(listOrder: ["b", "a"])
        #expect(queue.agentIDs == ["b", "a"])
    }

    @Test func leavingElsewhereAdvances() {
        var queue = FocusQueue(listOrder: ["a", "b", "c"])
        queue.moveForward()
        queue.update(listOrder: ["a", "c"])
        #expect(queue.currentID == "c")
    }

    @Test func leavingBeforeCurrentKeepsCard() {
        var queue = FocusQueue(listOrder: ["a", "b", "c"])
        queue.moveForward()
        queue.update(listOrder: ["b", "c"])
        #expect(queue.currentID == "b")
        #expect(queue.position == 1)
    }

    @Test func arrivalsAppendInListOrderWithoutStealing() {
        var queue = FocusQueue(listOrder: ["b", "d"])
        queue.update(listOrder: ["a", "b", "c", "d"])
        #expect(queue.agentIDs == ["b", "d", "a", "c"])
        #expect(queue.currentID == "b")
    }

    @Test func existingKeepPlaceWhenListReorders() {
        var queue = FocusQueue(listOrder: ["a", "b"])
        queue.update(listOrder: ["b", "a"])
        #expect(queue.agentIDs == ["a", "b"])
    }

    @Test func listOrderFollowsDisplayThenFeed() {
        let order = FocusQueue.listOrder(needsYou: ["x", "a", "b"], displayOrder: ["b", "w", "a"])
        #expect(order == ["b", "a", "x"])
    }
}

struct FocusTextFitTests {
    @Test func fitsAtBase() {
        #expect(FocusTextFit.fit(heightAtBase: 300, available: 500) == .base)
    }

    @Test func stepsDownUntilItFits() {
        // At 20pt: 600 * (20/22)^2 ≈ 495.9 ≤ 500; at 21pt ≈ 546.7 > 500.
        let fit = FocusTextFit.fit(heightAtBase: 600, available: 500)
        #expect(fit.body == 20)
        #expect(!fit.scrolls)
        #expect(fit.question > fit.body)
        #expect(fit.question < FocusTextFit.baseQuestion)
    }

    @Test func floorThenScrolls() {
        let fit = FocusTextFit.fit(heightAtBase: 5_000, available: 400)
        #expect(fit.body == FocusTextFit.floorBody)
        #expect(fit.question == FocusTextFit.floorQuestion)
        #expect(fit.scrolls)
    }

    @Test func unmeasuredUsesBase() {
        #expect(FocusTextFit.fit(heightAtBase: 0, available: 400) == .base)
        #expect(FocusTextFit.fit(heightAtBase: 100, available: 0) == .base)
    }

    @Test func questionSizeEnds() {
        #expect(FocusTextFit.questionSize(forBody: 22) == 26)
        #expect(FocusTextFit.questionSize(forBody: 15) == 18)
    }

    @Test func leftAndRightIndependent() {
        let left = FocusTextFit.fit(heightAtBase: 2_000, available: 500)
        let right = FocusTextFit.fit(heightAtBase: 200, available: 500)
        #expect(left.scrolls)
        #expect(right == .base)
    }
}

struct FocusHotkeyTests {
    @Test func defaultIsOptionShiftF() {
        let defaults = UserDefaults(suiteName: "FocusHotkeyTests-\(UUID())")!
        #expect(FocusHotkey.configured(defaults: defaults) == FocusHotkey.standard)
        #expect(FocusHotkey.standard.displayName == "⌥⇧F")
        #expect(FocusHotkey.standard != AgentHotkeyConfig.standard)
    }

    @Test func savesUnderItsOwnKeys() {
        let defaults = UserDefaults(suiteName: "FocusHotkeyTests-\(UUID())")!
        let custom = AgentHotkeyConfig(keyCode: 40, modifiers: [.command, .option], keyName: "K")
        FocusHotkey.save(custom, to: defaults)
        #expect(FocusHotkey.configured(defaults: defaults) == custom)
        #expect(AgentHotkeyConfig.configured(defaults: defaults) == .standard)
        FocusHotkey.save(FocusHotkey.standard, to: defaults)
        #expect(defaults.object(forKey: FocusHotkey.keys.keyCode) == nil)
    }
}
