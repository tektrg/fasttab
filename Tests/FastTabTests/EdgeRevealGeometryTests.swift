import Foundation
import Testing
@testable import FastTab

private let screenFrame = CGRect(x: 0, y: 0, width: 1600, height: 1000)

@Test func notchZoneUsesAuxiliaryAreasWhenNotchIsPhysical() async throws {
    let info = EdgeRevealGeometry.ScreenInfo(
        frame: screenFrame,
        safeAreaTopInset: 32,
        notchLeftAuxMaxX: 700,
        notchRightAuxMinX: 900
    )

    let zone = EdgeRevealGeometry.notchZone(info)

    #expect(zone == CGRect(x: 700, y: 968, width: 200, height: 32))
}

@Test func notchZoneFallsBackToFakePillWithoutAuxiliaryAreas() async throws {
    // Physical notch reported via safe area, but the macOS 12+ auxiliary-area
    // APIs returned nil (older OS, or a screen shape the APIs don't cover).
    let info = EdgeRevealGeometry.ScreenInfo(
        frame: screenFrame,
        safeAreaTopInset: 32,
        notchLeftAuxMaxX: nil,
        notchRightAuxMinX: nil
    )

    let zone = EdgeRevealGeometry.notchZone(info)

    #expect(zone.height == 32)
    #expect(zone.width == EdgeRevealGeometry.fallbackNotchSize.width)
    #expect(zone.midX == screenFrame.midX)
    #expect(zone.maxY == screenFrame.maxY)
}

@Test func notchZoneFallsBackToVirtualPillOnNonNotchedDisplay() async throws {
    // No physical notch at all (external monitor as primary, older MacBook,
    // clamshell) — the fake "virtual notch" pill from the plan.
    let info = EdgeRevealGeometry.ScreenInfo(
        frame: screenFrame,
        safeAreaTopInset: 0,
        notchLeftAuxMaxX: nil,
        notchRightAuxMinX: nil
    )

    let zone = EdgeRevealGeometry.notchZone(info)

    #expect(zone.size == EdgeRevealGeometry.fallbackNotchSize)
    #expect(zone.midX == screenFrame.midX)
    #expect(zone.maxY == screenFrame.maxY)
}

@Test func edgeBandZoneStaysInMiddleFortyPercentOfScreenHeight() async throws {
    let leftZone = EdgeRevealGeometry.edgeBandZone(screenFrame, style: .leftEdge)
    let rightZone = EdgeRevealGeometry.edgeBandZone(screenFrame, style: .rightEdge)

    // Middle 40% of a 1000pt-tall screen is 300...700.
    #expect(leftZone.minY == 300)
    #expect(leftZone.maxY == 700)
    #expect(leftZone.minX == screenFrame.minX)

    #expect(rightZone.minY == 300)
    #expect(rightZone.maxY == 700)
    #expect(rightZone.maxX == screenFrame.maxX)

    // Both stay well clear of the four screen corners.
    #expect(leftZone.minY > screenFrame.minY)
    #expect(leftZone.maxY < screenFrame.maxY)
}

@Test func triggerZoneIsNilWhenOff() async throws {
    let info = EdgeRevealGeometry.ScreenInfo(
        frame: screenFrame,
        safeAreaTopInset: 32,
        notchLeftAuxMaxX: 700,
        notchRightAuxMinX: 900
    )

    #expect(EdgeRevealGeometry.triggerZone(for: .off, screenInfo: info) == nil)
}

@Test func pillFrameHugsTheZoneItCameFrom() async throws {
    let notchZone = CGRect(x: 700, y: 968, width: 200, height: 32)
    let notchPill = EdgeRevealGeometry.pillFrame(for: .notch, zone: notchZone, screenFrame: screenFrame)

    #expect(notchPill.midX == notchZone.midX)
    #expect(notchPill.maxY == notchZone.minY - EdgeRevealGeometry.pillGap)

    let leftZone = EdgeRevealGeometry.edgeBandZone(screenFrame, style: .leftEdge)
    let leftPill = EdgeRevealGeometry.pillFrame(for: .leftEdge, zone: leftZone, screenFrame: screenFrame)

    #expect(leftPill.midY == leftZone.midY)
    #expect(leftPill.minX == screenFrame.minX + EdgeRevealGeometry.pillGap)

    let rightZone = EdgeRevealGeometry.edgeBandZone(screenFrame, style: .rightEdge)
    let rightPill = EdgeRevealGeometry.pillFrame(for: .rightEdge, zone: rightZone, screenFrame: screenFrame)

    #expect(rightPill.midY == rightZone.midY)
    #expect(rightPill.maxX == screenFrame.maxX - EdgeRevealGeometry.pillGap)
}
