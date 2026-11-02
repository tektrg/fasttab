import XCTest
@testable import FastTabMobile

/// When a released left-edge swipe closes the reader (slides out) or snaps it back.
final class ReaderSlideDismissalTests: XCTestCase {
    private let width: CGFloat = 390

    func testDraggedPastAThirdOfTheWidthCloses() {
        XCTAssertTrue(ReaderSlideDismissal.shouldDismiss(translation: 130, velocity: 0, width: width))
        XCTAssertTrue(ReaderSlideDismissal.shouldDismiss(translation: 300, velocity: 100, width: width))
    }

    func testShortSlowDragSnapsBack() {
        XCTAssertFalse(ReaderSlideDismissal.shouldDismiss(translation: 129, velocity: 0, width: width))
        XCTAssertFalse(ReaderSlideDismissal.shouldDismiss(translation: 60, velocity: 599, width: width))
    }

    func testFlickRightClosesEvenWhenShort() {
        XCTAssertTrue(ReaderSlideDismissal.shouldDismiss(translation: 30, velocity: 600, width: width))
    }

    func testMovingBackLeftKeepsTheReaderHoweverFar() {
        XCTAssertFalse(ReaderSlideDismissal.shouldDismiss(translation: 300, velocity: -300, width: width))
        XCTAssertTrue(ReaderSlideDismissal.shouldDismiss(translation: 300, velocity: -299, width: width))
    }

    func testNoMovementOrUnknownWidthNeverCloses() {
        XCTAssertFalse(ReaderSlideDismissal.shouldDismiss(translation: 0, velocity: 2000, width: width))
        XCTAssertFalse(ReaderSlideDismissal.shouldDismiss(translation: -20, velocity: 2000, width: width))
        XCTAssertFalse(ReaderSlideDismissal.shouldDismiss(translation: 200, velocity: 2000, width: 0))
    }

    func testProgressFollowsTheFingerWithinBounds() {
        XCTAssertEqual(ReaderSlideDismissal.progress(translation: 195, width: width), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ReaderSlideDismissal.progress(translation: -40, width: width), 0)
        XCTAssertEqual(ReaderSlideDismissal.progress(translation: 900, width: width), 1)
        XCTAssertEqual(ReaderSlideDismissal.progress(translation: 100, width: 0), 0)
    }
}
