import CoreGraphics
import Testing
@testable import AgentBar

struct AgentPanelLayoutTests {
    typealias F = AgentListFixtures

    @Test func ageTextIsCoarse() {
        #expect(AgentAge.shortText(5) == "<1m")
        #expect(AgentAge.shortText(240) == "4m")
        #expect(AgentAge.shortText(2 * 3_600 + 90) == "2h")
        #expect(AgentAge.shortText(3 * 86_400) == "3d")
    }

    @Test func ageTicksWithTimeSinceFetch() {
        let agent = F.agent("a")   // 120s in status at fetch
        #expect(AgentAge.seconds(for: agent, fetchedAt: F.now, now: F.now.addingTimeInterval(180)) == 300)
    }

    @Test func heightGrowsWithRowsThenCapsAtTheListMaximum() {
        let few = F.presentation(F.snapshot([F.agent("a"), F.agent("b")]))
        let many = F.presentation(F.snapshot((0..<40).map { F.agent("id\($0)") }))
        #expect(AgentPanelMetrics.height(for: few) < AgentPanelMetrics.height(for: many))
        #expect(AgentPanelMetrics.bodyHeight(for: many) == AgentPanelMetrics.maxListHeight)
    }

    @Test func messageStatesUseAFixedBody() {
        #expect(AgentPanelMetrics.bodyHeight(for: .connecting) == AgentPanelMetrics.messageHeight)
    }

    @Test func boardNoteAddsItsHeight() {
        let plain = F.presentation(F.snapshot([F.agent("a")]))
        let stale = F.presentation(F.snapshot([F.agent("a")], boardIsCurrent: false))
        #expect(AgentPanelMetrics.height(for: stale) - AgentPanelMetrics.height(for: plain) == AgentPanelMetrics.noteHeight)
    }

    @Test func theFooterIsAlwaysCountedInTheHeight() {
        let plain = F.presentation(F.snapshot([F.agent("a")]))
        let body = AgentPanelMetrics.searchFieldHeight + AgentPanelMetrics.dividerHeight + AgentPanelMetrics.bodyHeight(for: plain)
        #expect(AgentPanelMetrics.height(for: plain) == body + AgentPanelMetrics.footerHeight)
    }

    @Test func rowsBeforeScrollingSetTheListHeightLimit() {
        let many = F.presentation(F.snapshot((0..<40).map { F.agent("id\($0)") }))
        let six = AgentPanelMetrics.maxListHeight(visibleRows: 6)
        let sixteen = AgentPanelMetrics.maxListHeight(visibleRows: 16)
        #expect(six < AgentPanelMetrics.maxListHeight && AgentPanelMetrics.maxListHeight < sixteen)
        #expect(AgentPanelMetrics.bodyHeight(for: many, maxListHeight: six) == six)
        #expect(AgentPanelMetrics.height(for: many, maxListHeight: sixteen) > AgentPanelMetrics.height(for: many, maxListHeight: six))
    }

    @Test func theDefaultRowsBeforeScrollingKeepTheOriginalListHeight() {
        #expect(AgentPanelMetrics.maxListHeight == 520)
        #expect(AgentListSettings.standard.maxVisibleRows == AgentPanelMetrics.defaultMaxVisibleRows)
    }

    @Test func placementSitsInTheBottomRightAndKeepsTheBottomFixed() {
        let screen = CGRect(x: 100, y: 50, width: 1_000, height: 800)
        let short = AgentPanelPlacement.frame(size: CGSize(width: 400, height: 200), in: screen)
        let tall = AgentPanelPlacement.frame(size: CGSize(width: 400, height: 500), in: screen)
        #expect(short.maxX == screen.maxX - AgentPanelPlacement.edgeMargin)
        #expect(short.minY == screen.minY + AgentPanelPlacement.edgeMargin)
        #expect(short.minY == tall.minY)
    }

    @Test func placementNeverExceedsTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 500)
        let frame = AgentPanelPlacement.frame(size: CGSize(width: 400, height: 5_000), in: screen)
        #expect(frame.maxY <= screen.maxY - AgentPanelPlacement.edgeMargin)
        #expect(frame.minY >= screen.minY)
    }

    @Test func peekTakesTheFullListHeightEvenForAShortList() {
        let few = F.presentation(F.snapshot([F.agent("a")]))
        let peeking = AgentPanelMetrics.height(for: few, isPeeking: true)
        let listing = AgentPanelMetrics.height(for: few)
        #expect(peeking > listing)
        #expect(peeking == AgentPanelMetrics.height(for: F.presentation(F.snapshot((0..<40).map { F.agent("id\($0)") }))))
    }

    @Test func aGrowingSearchFieldAndTheRoutingRowNeverGrowTheWindowWhenTheListIsClamped() {
        let many = F.presentation(F.snapshot((0..<40).map { F.agent("id\($0)") }))   // list already at its max
        let plain = AgentPanelMetrics.height(for: many)
        let growing = AgentPanelMetrics.height(for: many, searchFieldLineCount: AgentPanelMetrics.searchFieldMaxLines, showsRoutingRow: true)
        #expect(growing == plain)   // borrowed from the list's own budget, not added to the total
    }

    @Test func aGrowingSearchFieldAndTheRoutingRowNeverGrowTheWindowForAShortListEither() {
        // Regression: a short list (well under maxListHeight, not scrolling) used to grow the
        // window because the borrow only kicked in once the list was already clamped at the cap.
        let few = F.presentation(F.snapshot([F.agent("a"), F.agent("b"), F.agent("c")]))
        let plain = AgentPanelMetrics.height(for: few)
        let growing = AgentPanelMetrics.height(for: few, searchFieldLineCount: AgentPanelMetrics.searchFieldMaxLines, showsRoutingRow: true)
        #expect(growing == plain)   // still absorbed by the content area, not added on top
    }

    @Test func aGrowingSearchFieldAndTheRoutingRowNeverGrowTheWindowForAFlatMessageStateEither() {
        // The connecting/feedDown/noAgents/noMatches states use a flat `messageHeight`, untouched
        // by list clamping entirely, so they need the same unconditional absorption.
        let plain = AgentPanelMetrics.height(for: .connecting)
        let growing = AgentPanelMetrics.height(for: .connecting, searchFieldLineCount: AgentPanelMetrics.searchFieldMaxLines, showsRoutingRow: true)
        #expect(growing == plain)
    }

    @Test func searchFieldLineCountEstimatesWrappingAndCapsAtTheMax() {
        #expect(AgentPanelMetrics.searchFieldLineCount(for: "") == 1)
        #expect(AgentPanelMetrics.searchFieldLineCount(for: "fix the login bug") == 1)
        let long = String(repeating: "a", count: 500)
        #expect(AgentPanelMetrics.searchFieldLineCount(for: long) == AgentPanelMetrics.searchFieldMaxLines)
    }

    @Test func composingCollapsesTheListAndTheBoardNoteToZeroHeight() {
        // Tab-tagged: the chip already names the target, so the list/status message and any
        // stale-board note below it are hidden (AgentPanelView) — the window must shrink to
        // match, not just visually clip.
        let many = F.presentation(F.snapshot((0..<40).map { F.agent("id\($0)") }))
        let stale = F.presentation(F.snapshot([F.agent("a")], boardIsCurrent: false))
        let composingMany = AgentPanelMetrics.height(for: many, isComposing: true)
        let composingStale = AgentPanelMetrics.height(for: stale, isComposing: true)
        let floor = AgentPanelMetrics.searchFieldHeight + AgentPanelMetrics.dividerHeight + AgentPanelMetrics.footerHeight
        #expect(composingMany == floor)
        #expect(composingStale == floor)   // the board note is suppressed too, not just the list
    }

    @Test func composingStillGrowsWithALongerTypedMessage() {
        // The field itself still reserves room for its own text (and the routing row, though
        // routing can't be active while tagged) even with the body collapsed.
        let few = F.presentation(F.snapshot([F.agent("a")]))
        let plain = AgentPanelMetrics.height(for: few, isComposing: true)
        let growing = AgentPanelMetrics.height(for: few, isComposing: true, searchFieldLineCount: AgentPanelMetrics.searchFieldMaxLines)
        #expect(growing > plain)
    }

    @Test func peekTextLinesFitInsideTheBody() {
        let body = AgentPanelMetrics.peekBodyHeight()
        let lines = AgentPanelMetrics.peekVisibleLineCount(bodyHeight: body)
        let used = AgentPanelMetrics.peekHeaderHeight + AgentPanelMetrics.peekReadLineHeight
            + 2 * AgentPanelMetrics.peekTextVerticalPadding + CGFloat(lines) * AgentPanelMetrics.peekTextLineHeight
        #expect(lines > 0 && used <= body)
    }
}
