import Foundation
import CoreGraphics
import Testing
@testable import FastTab
import IndieCommandBar

/// Pins Fast Tab's command-bar sizes so moving the sizing math into
/// IndieCommandBar (`CommandBarSizing`) cannot change them.
struct CommandBarSizingPinTests {
    @Test func constants() {
        #expect(CommandBarLayout.visibleResultRows == 5)
        #expect(CommandBarLayout.compactGearRowHeight == 16)
        #expect(CommandBarLayout.interSectionSpacing == 10)
        #expect(CommandBarLayout.minQuickOpenItemLimit == 3)
        #expect(CommandBarLayout.maxQuickOpenItemLimit == 15)
        #expect(CommandBarLayout.expandedAllTabsMaxHeight == 600)
    }

    @Test func surfaceSizes() {
        #expect(CommandBarLayout.surfaceSize(for: .notch, topInset: 0) == CGSize(width: 640, height: 122 + 66 * 5))
        #expect(CommandBarLayout.surfaceSize(for: .leftEdge) == CGSize(width: 320, height: 152 + 80 * 5))
        #expect(CommandBarLayout.surfaceSize(for: .rightEdge, rowStyle: .minimal, rowCount: 2) == CGSize(width: 320, height: 152 + 40 * 2))
        #expect(CommandBarLayout.surfaceSize(for: .notch, showFooter: false, topInset: 0).height == CGFloat(428))
        #expect(CommandBarLayout.surfaceSize(for: .leftEdge, showFooter: false).height == CGFloat(488))
        #expect(CommandBarLayout.surfaceSize(for: .notch, rowStyle: .minimal, rowCount: 3, topInset: 12) == CGSize(width: 640.0 * 2.0 / 3.0, height: 254))
        #expect(CommandBarLayout.surfaceSize(for: .notch, rowCount: 0, maxRows: 9, topInset: 0).height == CGFloat(188))
        #expect(CommandBarLayout.surfaceSize(for: .notch, maxRows: 9, topInset: 0).height == CGFloat(716))
    }

    @Test func resultsHeights() {
        #expect(CommandBarLayout.resultsHeight(for: .notch) == 330)
        #expect(CommandBarLayout.resultsHeight(for: .leftEdge, rowCount: 2) == 160)
        #expect(CommandBarLayout.resultsHeight(for: .notch, rowStyle: .minimal, rowCount: 20, maxRows: 7) == 280)
    }

    @Test func rowCaps() {
        #expect(CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 982, rowStyle: .full, reservedTopInset: 32) == 12)
        #expect(CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 2000, rowStyle: .full) == 15)
        #expect(CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 200, rowStyle: .minimal) == 3)
        #expect(CommandBarLayout.maxQuickOpenRows(fittingScreenHeight: 600, rowStyle: .minimal) == 11)
        #expect(CommandBarLayout.expandedAllTabsMaxRows(for: .leftEdge, rowStyle: .full) == 5)
        #expect(CommandBarLayout.expandedAllTabsMaxRows(for: .rightEdge, rowStyle: .minimal, showFooter: false) == 12)
        #expect(CommandBarLayout.minimumCanvasSize(fittingScreenHeight: 982, reservedTopInset: 32) == CGSize(width: 640, height: 122 + 66 * 12 + 32))
    }

    @Test func framesAndDismiss() {
        let canvas = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let frame = CommandBarLayout.surfaceFrame(in: canvas, anchor: .leftEdge, maxRows: 5)
        #expect(frame == CGRect(x: 0, y: (1000 - 552) / 2, width: 320, height: 552))
        let right = CommandBarLayout.surfaceFrame(in: canvas, anchor: .rightEdge, rowStyle: .minimal, maxRows: 4, showFooter: false)
        #expect(right == CGRect(x: 1280, y: (1000 - (152 - 64 + 160)) / 2, width: 320, height: 152 - 64 + 160))
        #expect(CommandBarLayout.shouldDismissClick(at: CGPoint(x: 1500, y: 500), in: canvas, anchor: .leftEdge))
        #expect(!CommandBarLayout.shouldDismissClick(at: CGPoint(x: 10, y: 500), in: canvas, anchor: .leftEdge))
        #expect(CommandBarLayout.surfaceOffset(canvasSize: canvas.size, anchor: .leftEdge, maxRows: 5) == CGSize(width: -640, height: 0))
        let small = CGRect(x: 100, y: 100, width: 400, height: 300)
        let canvasFrame = CommandBarLayout.canvasFrame(for: small)
        #expect(canvasFrame.midX == small.midX && canvasFrame.midY == small.midY)
        #expect(canvasFrame.width >= 640)
    }

    @Test func searchActivityAndDismissDelay() {
        #expect(CommandBarLayout.isSearchActive(searchText: "a"))
        #expect(CommandBarLayout.isSearchActive(searchText: "", hasScopeChips: true))
        #expect(CommandBarLayout.isSearchEmpty(searchText: ""))
        let now = Date()
        #expect(CommandBarLayout.hoverDismissDelay(lastTypingDate: nil, now: now) == 0.35)
        #expect(CommandBarLayout.hoverDismissDelay(lastTypingDate: now.addingTimeInterval(-0.5), now: now) == 1.5)
        #expect(CommandBarLayout.hoverDismissDelay(lastTypingDate: now.addingTimeInterval(-5), now: now) == 0.35)
    }
}
