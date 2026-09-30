import AppKit
import SwiftUI
import Testing
@testable import CommandBarKit
import IndieEdgeReveal

@Test func commandBarReservesTopInsetOnlyForAPhysicallyNotchedDisplay() async throws {
    // Edge surfaces are vertically centered and never reach the top edge.
    #expect(CommandBarLayout.surfaceTopInset(for: .leftEdge) == 0)
    #expect(CommandBarLayout.surfaceTopInset(for: .rightEdge) == 0)

    // The notch surface does reach the top edge, so it clears a *physical*
    // notch — and only that. On a display without one (external monitor,
    // clamshell, older MacBook) the reserved band is pure empty space, since
    // the bar already draws above the menu-bar layer.
    let openingScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let isNotched = openingScreen.map { EdgeRevealScreenInfo(screen: $0).hasPhysicalNotch } ?? false

    #expect((CommandBarLayout.surfaceTopInset(for: .notch) > 0) == isNotched)
}

@Test func commandBarSurfaceSilhouetteStaysFlushAndFlaresOnlyAtTheHuggedEdge() async throws {
    // The shape is handed the surface outset by the flare room on all sides
    // (`CommandBarSurface` does this with negative padding). It must draw its
    // hugged edge exactly on the surface's own edge — a shape that flared in
    // that direction too would lift the bar off the screen edge — and spend
    // the outset only sideways, on the flare.
    let flare = CommandBarLayout.surfaceJoinRadius
    #expect(flare > 0)
    #expect(flare < CommandBarLayout.surfaceCornerRadius)

    let surface = CGRect(x: 40, y: 60, width: 380, height: 300)
    let outset = surface.insetBy(dx: -flare, dy: -flare)

    let notch = CommandBarSurfaceShape(anchor: .notch).path(in: outset).boundingRect
    #expect(abs(notch.minY - surface.minY) < 0.5)
    #expect(abs(notch.maxY - surface.maxY) < 0.5)
    #expect(notch.minX < surface.minX)
    #expect(notch.maxX > surface.maxX)

    let left = CommandBarSurfaceShape(anchor: .leftEdge).path(in: outset).boundingRect
    #expect(abs(left.minX - surface.minX) < 0.5)
    #expect(abs(left.maxX - surface.maxX) < 0.5)
    #expect(left.minY < surface.minY)
    #expect(left.maxY > surface.maxY)

    let right = CommandBarSurfaceShape(anchor: .rightEdge).path(in: outset).boundingRect
    #expect(abs(right.maxX - surface.maxX) < 0.5)
    #expect(abs(right.minX - surface.minX) < 0.5)
    #expect(right.minY < surface.minY)
    #expect(right.maxY > surface.maxY)
}

@Test func commandBarRevealAxisRunsFromTheSliverToFullSizeAndPassesOvershootThrough() async throws {
    // Each axis of the reveal is its own spring, so each is driven by a plain
    // 0...1 progress. Progress past 1 is the spring settling and must reach the
    // scale unclamped — clamping it would flatten the bounce out of the reveal.
    let start: CGFloat = 0.12
    #expect(CommandBarLayout.revealAxis(from: start, progress: 0) == start)
    #expect(CommandBarLayout.revealAxis(from: start, progress: 1) == 1)
    #expect(CommandBarLayout.revealAxis(from: start, progress: 0.5) == (start + 1) / 2)
    #expect(CommandBarLayout.revealAxis(from: start, progress: 1.05) > 1)
}

@Test func commandBarRevealContentFadeSpansOnlyTheEarlyPartOfTheGrowth() async throws {
    let opacity = CommandBarLayout.revealContentOpacity

    // The panel's very first rendered frame jumps straight to
    // `instantReactionFraction`, which is the fade's lower bound — the shell has
    // to arrive with no content painted on it at all.
    #expect(opacity(CommandBarLayout.revealContentFadeRange.lowerBound, 1) == 0)
    // Anything before that (including the pre-reveal sliver) stays transparent
    // rather than going negative.
    #expect(opacity(0, 0) == 0)

    // Fully opaque short of full size, so the spring's settle plays out on
    // solid content.
    #expect(opacity(CommandBarLayout.revealContentFadeRange.upperBound, 1) == 1)
    #expect(CommandBarLayout.revealContentFadeRange.upperBound < 1)

    // The slower axis governs: content must not be solid while one axis is
    // still barely out of the edge.
    #expect(opacity(1, CommandBarLayout.revealContentFadeRange.lowerBound) == 0)

    // Overshoot past 1 clamps instead of producing an invalid opacity.
    #expect(opacity(1.06, 1.04) == 1)

    // Monotonic across the ramp.
    let midpoint = opacity(0.7, 0.7)
    #expect(midpoint > 0 && midpoint < 1)
    #expect(opacity(0.6, 0.6) < midpoint)
    #expect(opacity(0.8, 0.8) > midpoint)
}

@Test func commandBarSurfaceTailFadeOnlyAffectsTheCollapse() async throws {
    let opacity = CommandBarLayout.revealSurfaceOpacity

    // Fully gone at the pre-reveal scale — that scale is a *notch-sized block*,
    // not zero, so without this the collapse still had a visible block on screen
    // at the instant the window was ordered out.
    #expect(opacity(0, 0) == 0)
    // Partly faded through the tail band.
    let tail = opacity(CommandBarLayout.revealSurfaceFadeCeiling / 2, 1)
    #expect(tail > 0 && tail < 1)
    // Solid from the ceiling onwards, and the reveal's first rendered frame sits
    // above it — so the panel never fades *in*, only out.
    #expect(opacity(CommandBarLayout.revealSurfaceFadeCeiling, 1) == 1)
    #expect(CommandBarLayout.revealSurfaceFadeCeiling < CommandBarLayout.revealContentFadeRange.lowerBound)
    // Overshoot past 1 clamps.
    #expect(opacity(1.06, 1.04) == 1)
}

@Test func commandBarSurfaceAlignmentMatchesTheAnchoredEdge() async throws {
    // The live bar is flushed against its edge by *alignment*, not by offsetting
    // half the measured canvas. Measuring lags the window by a layout pass, so
    // the first rendered frame after the window moved to another display drew
    // the bar inset from its edge (204pt between a 1512pt and a 1920pt-wide
    // display; dead centre on the first open after launch) before snapping
    // flush. Alignment resolves inside the same layout pass, so it cannot lag.
    #expect(CommandBarLayout.surfaceAlignment(for: .notch) == .top)
    #expect(CommandBarLayout.surfaceAlignment(for: .leftEdge) == .leading)
    #expect(CommandBarLayout.surfaceAlignment(for: .rightEdge) == .trailing)

    // Each anchor's alignment has to agree with the side its shape leaves flat
    // and the side the reveal scales out of, or the bar would grow out of one
    // edge while sitting against another.
    for anchor in CommandBarAnchor.allCases {
        let alignment = CommandBarLayout.surfaceAlignment(for: anchor)
        let unitPoint = CommandBarLayout.revealAnchorUnitPoint(for: anchor)
        if alignment == .top {
            #expect(unitPoint == .top)
        } else if alignment == .leading {
            #expect(unitPoint == .leading)
        } else {
            #expect(unitPoint == .trailing)
        }
    }
}

@Test func commandBarShadowShiftPointsAwayFromTheAnchoredEdge() async throws {
    // Down for the notch, inboard for the side anchors — the shadow is only
    // ever cast away from the edge the panel is hinged on.
    #expect(CommandBarLayout.shadowShiftVector(for: .notch) == CGSize(width: 0, height: CommandBarLayout.shadowDirectionalShift))
    #expect(CommandBarLayout.shadowShiftVector(for: .leftEdge) == CGSize(width: CommandBarLayout.shadowDirectionalShift, height: 0))
    #expect(CommandBarLayout.shadowShiftVector(for: .rightEdge) == CGSize(width: -CommandBarLayout.shadowDirectionalShift, height: 0))
}
