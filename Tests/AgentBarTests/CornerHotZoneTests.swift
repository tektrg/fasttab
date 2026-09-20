import CoreGraphics
import Testing
@testable import AgentBar

struct CornerHotZoneTests {
    private let single = [CGRect(x: 0, y: 0, width: 1_440, height: 900)]

    @Test func theBottomRightCornerIsHot() {
        #expect(CornerHotZone.contains(CGPoint(x: 1_440, y: 0), displayFrames: single))
        #expect(CornerHotZone.contains(CGPoint(x: 1_435, y: 5), displayFrames: single))
    }

    @Test func otherCornersAndEdgesAreNot() {
        #expect(!CornerHotZone.contains(CGPoint(x: 0, y: 0), displayFrames: single))
        #expect(!CornerHotZone.contains(CGPoint(x: 1_440, y: 900), displayFrames: single))
        #expect(!CornerHotZone.contains(CGPoint(x: 1_440, y: 400), displayFrames: single))
        #expect(!CornerHotZone.contains(CGPoint(x: 700, y: 0), displayFrames: single))
        #expect(!CornerHotZone.contains(CGPoint(x: 1_400, y: 40), displayFrames: single))
    }

    @Test func aPointOutsideEveryDisplayIsNotHot() {
        #expect(!CornerHotZone.contains(CGPoint(x: 2_000, y: -50), displayFrames: single))
    }

    @Test func aSeamWithAnotherDisplayToTheRightIsNotACorner() {
        let frames = [single[0], CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)]
        #expect(!CornerHotZone.contains(CGPoint(x: 1_440, y: 0), displayFrames: frames))
        // The far display's own bottom-right corner still is.
        #expect(CornerHotZone.contains(CGPoint(x: 3_360, y: 0), displayFrames: frames))
    }

    @Test func aDisplayBelowMakesItsBottomEdgeASeam() {
        let frames = [single[0], CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080)]
        #expect(!CornerHotZone.contains(CGPoint(x: 1_440, y: 0), displayFrames: frames))
    }

    @Test func aDisplayBesideButNotAtThePointersHeightIsNotASeam() {
        // A display to the right that starts above the corner: the corner at the bottom is a real edge.
        let frames = [single[0], CGRect(x: 1_440, y: 400, width: 1_000, height: 700)]
        #expect(CornerHotZone.contains(CGPoint(x: 1_440, y: 0), displayFrames: frames))
    }

    @Test func aMacBookNotchOrMenuBarChangesNothingBecauseTheFullFrameIsUsed() {
        // Frames are the displays' full frames, not their visible areas.
        let frame = [CGRect(x: 0, y: 0, width: 1_512, height: 982)]
        #expect(CornerHotZone.contains(CGPoint(x: 1_512, y: 0), displayFrames: frame))
    }
}
