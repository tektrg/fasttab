import CoreGraphics
import Foundation
import IndieCommandBar
import Testing
@testable import FastTab

/// QA 2026-11-15: "is the pointer on the bar" (mouse takeover, the "has visited" check, the leave
/// close) used the tall every-tab box even while a live search at a top position draws the short
/// panel, so a twitch over empty screen below it cancelled release-to-open or counted as a visit.
/// It is now the bar as drawn.
struct FastTabPointerDrawnBarTests {
    private let panel = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func defaults() -> UserDefaults {
        let name = "FastTabPointerDrawnBarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func surface(_ anchor: CommandBarAnchor, searching: Bool, defaults: UserDefaults) -> CGRect {
        CommandBarLayout.surfaceFrame(
            in: panel, anchor: anchor, rowStyle: CommandBarLayout.storedRowStyle(in: defaults),
            maxRows: CommandBarLayout.drawnSurfaceMaxRows(view: .recents, isSearching: searching, anchor: anchor, defaults: defaults),
            showFooter: CommandBarLayout.storedShowFooter(in: defaults)
        )
    }

    private func isOutside(
        _ point: CGPoint, _ anchor: CommandBarAnchor, searching: Bool, defaults: UserDefaults, notice: CGRect? = nil,
        followsMouse: Bool = false, pointer: CGPoint? = nil
    ) -> Bool {
        FastTabPointerLeaveGates.isOutsideDrawnBar(
            point, panelFrame: panel, visibleFrame: nil,
            position: CommandBarResolvedPosition(anchor: anchor, followsMouse: followsMouse), pointer: pointer,
            view: .recents, isSearching: searching, defaults: defaults, errorNoticeInWindow: notice
        )
    }

    @Test func belowTheShortSearchPanelIsOffTheBar() {
        let defaults = defaults()
        let short = surface(.notch, searching: true, defaults: defaults)
        let tall = surface(.notch, searching: false, defaults: defaults)
        let belowShort = CGPoint(x: short.midX, y: short.minY - 40)
        #expect(tall.contains(belowShort))                                   // the old box swallowed it
        #expect(isOutside(belowShort, .notch, searching: true, defaults: defaults))
        // Empty search: the tall list is drawn there, so it is on the bar.
        #expect(!isOutside(belowShort, .notch, searching: false, defaults: defaults))
    }

    @Test func theEdgeOutsetStillCounts() {
        let defaults = defaults()
        let short = surface(.notch, searching: true, defaults: defaults)
        let justBelow = CGPoint(x: short.midX, y: short.minY - FastTabPointerLeaveGates.outset + 1)
        #expect(!isOutside(justBelow, .notch, searching: true, defaults: defaults))
        let pastIt = CGPoint(x: short.midX, y: short.minY - FastTabPointerLeaveGates.outset - 1)
        #expect(isOutside(pastIt, .notch, searching: true, defaults: defaults))
    }

    /// Side edges keep the tall panel while searching (the search box never jumps), so the same
    /// spot is still on the bar there.
    @Test func positionsThatStayTallWhileSearchingKeepTheTallBox() {
        let defaults = defaults()
        let tall = surface(.leftEdge, searching: false, defaults: defaults)
        let nearBottom = CGPoint(x: tall.midX, y: tall.minY + 10)
        #expect(!isOutside(nearBottom, .leftEdge, searching: true, defaults: defaults))
    }

    /// The error notice hangs outside the bar: the pointer on it is still on the bar.
    @Test func theErrorNoticeCountsAsTheBar() {
        let defaults = defaults()
        let short = surface(.notch, searching: true, defaults: defaults)
        let point = CGPoint(x: short.midX, y: short.minY - 40)
        // Window coordinates are top-left origin; the panel frame is the window frame.
        let noticeInWindow = CGRect(x: point.x - 50, y: panel.maxY - point.y - 10, width: 100, height: 20)
        #expect(!isOutside(point, .notch, searching: true, defaults: defaults, notice: noticeInWindow))
    }

    /// Merge of the keyboard leave rule with per-open placement (2026-11-16): a hover-edge open
    /// slides the bar to the pointer, so "on the bar" is the slid bar, not the centred one.
    @Test func aBarSlidToThePointerIsHitTestedWhereItIsDrawn() {
        let defaults = defaults()
        let pointer = CGPoint(x: 200, y: 4)
        let position = CommandBarResolvedPosition(anchor: .bottomEdge, followsMouse: true)
        let maxRows = CommandBarLayout.drawnSurfaceMaxRows(view: .recents, isSearching: false, anchor: .bottomEdge, defaults: defaults)
        let slid = CommandBarLayout.surfaceFrame(
            in: panel, position: position, pointer: pointer, rowStyle: CommandBarLayout.storedRowStyle(in: defaults),
            maxRows: maxRows, showFooter: CommandBarLayout.storedShowFooter(in: defaults)
        )
        let centred = surface(.bottomEdge, searching: false, defaults: defaults)
        #expect(slid.midX < centred.midX)                                     // it really moved
        let onSlidOnly = CGPoint(x: slid.minX + 10, y: slid.midY)
        #expect(!centred.insetBy(dx: -FastTabPointerLeaveGates.outset, dy: -FastTabPointerLeaveGates.outset).contains(onSlidOnly))
        #expect(!isOutside(onSlidOnly, .bottomEdge, searching: false, defaults: defaults, followsMouse: true, pointer: pointer))
        #expect(isOutside(onSlidOnly, .bottomEdge, searching: false, defaults: defaults))   // centred bar: off it
    }
}
