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

    @Test func placementCentresHorizontallyAndKeepsTheTopFixed() {
        let screen = CGRect(x: 100, y: 0, width: 1_000, height: 800)
        let short = AgentPanelPlacement.frame(size: CGSize(width: 400, height: 200), in: screen)
        let tall = AgentPanelPlacement.frame(size: CGSize(width: 400, height: 500), in: screen)
        #expect(short.midX == screen.midX)
        #expect(short.maxY == tall.maxY)
    }

    @Test func placementNeverExceedsTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1_000, height: 500)
        let frame = AgentPanelPlacement.frame(size: CGSize(width: 400, height: 5_000), in: screen)
        #expect(frame.minY >= screen.minY)
    }
}
