import Foundation
import CoreGraphics
import Testing
@testable import FastTab
import CommandBarKit

struct CommandBarLayoutViewSizingTests {
    @Test func outsideClickBoxAlwaysContainsOutsideHoverBox() {
        let canvasFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let anchors = CommandBarAnchor.allCases
        let rowStyles: [ResultRowStyle] = [.minimal, .full]
        let footers: [Bool] = [true, false]
        let views: [CommandBarView] = CommandBarView.allCases
        let allTabsStates: [Bool] = [false, true]
        let quickOpenLimits = [CommandBarLayout.minQuickOpenItemLimit, 5, 10, CommandBarLayout.maxQuickOpenItemLimit]

        for anchor in anchors {
            let clickBox = CommandBarLayout.surfaceFrame(
                in: canvasFrame,
                anchor: anchor
            )

            for view in views {
                for rowStyle in rowStyles {
                    for showFooter in footers {
                        for isShowingAll in allTabsStates {
                            for limit in quickOpenLimits {
                                let maxRows = CommandBarLayout.surfaceMaxRows(
                                    view: view,
                                    isShowingAllOpenTabs: isShowingAll,
                                    isSearching: false,
                                    anchor: anchor,
                                    rowStyle: rowStyle,
                                    showFooter: showFooter,
                                    quickOpenLimit: limit
                                )

                                let hoverBox = CommandBarLayout.surfaceFrame(
                                    in: canvasFrame,
                                    anchor: anchor,
                                    rowStyle: rowStyle,
                                    maxRows: maxRows,
                                    showFooter: showFooter
                                )

                                // Floating-point rounding tolerance: 0.5pt
                                let contains = clickBox.minX <= hoverBox.minX + 0.5
                                    && clickBox.maxX >= hoverBox.maxX - 0.5
                                    && clickBox.minY <= hoverBox.minY + 0.5
                                    && clickBox.maxY >= hoverBox.maxY - 0.5

                                #expect(
                                    contains,
                                    "Click box \(clickBox) does not contain hover box \(hoverBox) for anchor=\(anchor), view=\(view), rowStyle=\(rowStyle), footer=\(showFooter), allTabs=\(isShowingAll), limit=\(limit)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
