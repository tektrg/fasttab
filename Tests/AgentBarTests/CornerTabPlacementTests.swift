import CoreGraphics
import IndieEdgeReveal
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

    // MARK: - Hover spots

    private let screen = CGRect(x: 100, y: 50, width: 1_000, height: 700)
    private let margin = AgentPanelPlacement.edgeMargin

    @Test func hoverOffKeepsTheBottomRightPlacement() {
        #expect(CornerTabPlacement.windowFrame(in: screen, spot: .off) == CornerTabPlacement.windowFrame(in: screen))
        #expect(CornerTabPlacement.windowFrame(in: screen, spot: .bottomRightCorner) == CornerTabPlacement.windowFrame(in: screen))
    }

    @Test func everySpotSitsInsideTheScreenWithTheMarginOnTheOpenSides() {
        for spot in EdgeRevealStyle.allCases {
            let frame = CornerTabPlacement.windowFrame(in: screen, spot: spot)
            #expect(screen.contains(frame), "\(spot)")
            switch CornerTabSlide(spot: spot) {
            case .fromRight: #expect(frame.maxX == screen.maxX && frame.width == CornerTabPlacement.tabWidth + margin)
            case .fromLeft: #expect(frame.minX == screen.minX && frame.width == CornerTabPlacement.tabWidth + margin)
            case .fromTop: #expect(frame.maxY == screen.maxY && frame.height == CornerTabPlacement.tabHeight + margin)
            case .fromBottom: #expect(frame.minY == screen.minY && frame.height == CornerTabPlacement.tabHeight + margin)
            }
        }
    }

    @Test func cornersKeepTheMarginFromTheirOtherEdge() {
        #expect(CornerTabPlacement.windowFrame(in: screen, spot: .topRightCorner).maxY == screen.maxY - margin)
        #expect(CornerTabPlacement.windowFrame(in: screen, spot: .bottomLeftCorner).minY == screen.minY + margin)
        let topLeft = CornerTabPlacement.windowFrame(in: screen, spot: .topLeftCorner)
        #expect(topLeft.minX == screen.minX && topLeft.maxY == screen.maxY - margin)
    }

    @Test func edgesAndNotchAreCentred() {
        #expect(CornerTabPlacement.windowFrame(in: screen, spot: .notch).midX == screen.midX)
        #expect(CornerTabPlacement.windowFrame(in: screen, spot: .bottomEdge).midX == screen.midX)
        #expect(CornerTabPlacement.windowFrame(in: screen, spot: .leftEdge).midY == screen.midY)
        #expect(CornerTabPlacement.windowFrame(in: screen, spot: .rightEdge).midY == screen.midY)
    }

    @Test func slideComesFromTheSpotsSide() {
        #expect(CornerTabSlide(spot: .bottomRightCorner) == .fromRight)
        #expect(CornerTabSlide(spot: .off) == .fromRight)
        #expect(CornerTabSlide(spot: .topLeftCorner) == .fromLeft)
        #expect(CornerTabSlide(spot: .leftEdge) == .fromLeft)
        #expect(CornerTabSlide(spot: .notch) == .fromTop)
        #expect(CornerTabSlide(spot: .bottomEdge) == .fromBottom)
    }

    @Test func cardWindowIsTallerAndStaysOnScreenAtEverySpot() {
        for spot in EdgeRevealStyle.allCases {
            let frame = CornerTabPlacement.cardWindowFrame(in: screen, spot: spot)
            #expect(screen.contains(frame), "\(spot)")
        }
    }
}
