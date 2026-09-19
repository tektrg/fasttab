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

    @Test func peekTextLinesFitInsideTheBody() {
        let body = AgentPanelMetrics.peekBodyHeight()
        let lines = AgentPanelMetrics.peekVisibleLineCount(bodyHeight: body)
        let used = AgentPanelMetrics.peekHeaderHeight + AgentPanelMetrics.peekReadLineHeight
            + 2 * AgentPanelMetrics.peekTextVerticalPadding + CGFloat(lines) * AgentPanelMetrics.peekTextLineHeight
        #expect(lines > 0 && used <= body)
    }
}
