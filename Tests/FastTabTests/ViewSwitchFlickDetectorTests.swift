import Foundation
import Testing
@testable import FastTab

struct ViewSwitchFlickDetectorTests {
    @Test func swipeLeftSwitchesForward() {
        var detector = ViewSwitchFlickDetector()

        // 3 sub-threshold scroll ticks (-20 each) = -60 total
        let t1 = detector.handleScroll(deltaX: -20, isEnded: false, currentView: .recents)
        #expect(t1 == nil)
        let t2 = detector.handleScroll(deltaX: -20, isEnded: false, currentView: .recents)
        #expect(t2 == nil)
        let t3 = detector.handleScroll(deltaX: -20, isEnded: false, currentView: .recents)
        #expect(t3 == .myOrder)

        // Momentum events while gesture is still ongoing are suppressed
        let momentum = detector.handleScroll(deltaX: -30, isEnded: false, currentView: .myOrder)
        #expect(momentum == nil)

        // End of gesture resets suppression
        _ = detector.handleScroll(deltaX: 0, isEnded: true, currentView: .myOrder)
        #expect(detector.isSuppressed == false)
        #expect(detector.accumulator == 0)

        // Next gesture switches from myOrder to bookmarks
        let t4 = detector.handleScroll(deltaX: -65, isEnded: false, currentView: .myOrder)
        #expect(t4 == .bookmarks)
    }

    @Test func swipeRightSwitchesBackward() {
        var detector = ViewSwitchFlickDetector()

        let t1 = detector.handleScroll(deltaX: 65, isEnded: false, currentView: .bookmarks)
        #expect(t1 == .myOrder)

        _ = detector.handleScroll(deltaX: 0, isEnded: true, currentView: .myOrder)

        let t2 = detector.handleScroll(deltaX: 65, isEnded: false, currentView: .myOrder)
        #expect(t2 == .recents)
    }

    @Test func directionClampingAtEdges() {
        var detector = ViewSwitchFlickDetector()

        // At recents: swipe right (backward) clamped
        let r1 = detector.handleScroll(deltaX: 80, isEnded: false, currentView: .recents)
        #expect(r1 == nil)
        #expect(detector.accumulator == 0)

        // At bookmarks: swipe left (forward) clamped
        let b1 = detector.handleScroll(deltaX: -80, isEnded: false, currentView: .bookmarks)
        #expect(b1 == nil)
        #expect(detector.accumulator == 0)
    }

    @Test func verticalScrollDoesNotTriggerFlickAndResetsAccumulator() {
        var detector = ViewSwitchFlickDetector()

        // Minor horizontal drift (-10) alongside dominant vertical scroll (deltaY = 40)
        let t1 = detector.handleScroll(deltaX: -10, deltaY: 40, isEnded: false, currentView: .recents)
        #expect(t1 == nil)
        #expect(detector.accumulator == 0)

        // Multiple vertical scroll events with small horizontal drift must not accumulate
        for _ in 0..<10 {
            _ = detector.handleScroll(deltaX: -15, deltaY: 30, isEnded: false, currentView: .recents)
        }
        #expect(detector.accumulator == 0)

        // Sub-pixel horizontal jitter (< 1.5) without vertical scroll is filtered
        let jitter = detector.handleScroll(deltaX: 1.0, deltaY: 0, isEnded: false, currentView: .myOrder)
        #expect(jitter == nil)
        #expect(detector.accumulator == 0)

        // Legitimate horizontal flick with minor vertical drift triggers properly
        let flick = detector.handleScroll(deltaX: -65, deltaY: 5, isEnded: false, currentView: .recents)
        #expect(flick == .myOrder)
    }

    @Test func momentumScrollNeverTriggersFlick() {
        var detector = ViewSwitchFlickDetector()

        // Momentum events even with large horizontal deltas must not trigger flick or accumulate
        let m1 = detector.handleScroll(deltaX: -80, isEnded: false, isMomentum: true, currentView: .recents)
        #expect(m1 == nil)
        #expect(detector.accumulator == 0)

        let m2 = detector.handleScroll(deltaX: -100, isEnded: false, isMomentum: true, currentView: .recents)
        #expect(m2 == nil)
        #expect(detector.accumulator == 0)

        // Ending gesture resets state
        _ = detector.handleScroll(deltaX: 0, isEnded: true, isMomentum: false, currentView: .recents)
        #expect(detector.isSuppressed == false)
        #expect(detector.accumulator == 0)
    }
}
