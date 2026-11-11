import Testing
@testable import FastTab

@Suite struct RowRemovalExitTests {
    @Test func dismissedRowStaysOffscreenUntilFinished() {
        var exit = RowRemovalExit()
        #expect(exit.begin("a") == nil)
        #expect(exit.isExiting("a"))
        // Removing the row from the list must not bring it back: still exiting.
        #expect(exit.isExiting("a"))
        #expect(exit.finish("a", stillListed: false) == false)
        #expect(!exit.isExiting("a"))
    }

    @Test func failedCloseSlidesRowBack() {
        var exit = RowRemovalExit()
        _ = exit.begin("a")
        #expect(exit.finish("a", stillListed: true) == true)
        #expect(!exit.isExiting("a"))
    }

    @Test func newerRemovalSupersedesAndIsNotClearedByOldTask() {
        var exit = RowRemovalExit()
        _ = exit.begin("a")
        #expect(exit.begin("b") == "a")
        #expect(exit.finish("a", stillListed: false) == false)
        #expect(exit.isExiting("b"))
    }

    @Test func sameRowAgainIsNotSuperseded() {
        var exit = RowRemovalExit()
        _ = exit.begin("a")
        #expect(exit.begin("a") == nil)
    }
}
