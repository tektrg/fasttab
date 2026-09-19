import CoreGraphics
import Testing
@testable import AgentBar

struct CornerTabPlacementTests {
    @Test func windowRunsFromTheTabToTheRightEdgeAtThePanelsBottomMargin() {
        let display = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        let frame = CornerTabPlacement.windowFrame(in: display)
        #expect(frame.maxX == display.maxX)
        #expect(frame.minY == display.minY + AgentPanelPlacement.edgeMargin)
        #expect(frame.width == CornerTabPlacement.tabWidth + AgentPanelPlacement.edgeMargin)
        // The tab itself ends where the panel ends.
        #expect(frame.maxX - AgentPanelPlacement.edgeMargin == display.maxX - AgentPanelPlacement.edgeMargin)
    }

    @Test func theTabSitsInsideThePanelsFootprint() {
        let display = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let panel = AgentPanelPlacement.frame(size: CGSize(width: AgentPanelMetrics.width, height: 300), in: display)
        let tab = CornerTabPlacement.windowFrame(in: display)
        #expect(tab.minX >= panel.minX)
        #expect(tab.minY == panel.minY)
    }
}
