import Foundation
import Testing
import HeroMotion

/// The onboarding hero clock shared by the Mac and iPhone onboarding:
/// loops repeat forever, one-shots rest on their last frame, pauses resume
/// cleanly, and the easing curves stay in range.
struct HeroTimelineTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private let loop = HeroPlayback.loop(period: 4, restAt: 3)

    private func isClose(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    // MARK: - Playback

    @Test func loopRepeatsForever() {
        #expect(isClose(loop.frameTime(elapsed: 1), 1))
        #expect(isClose(loop.frameTime(elapsed: 5), 1))
        #expect(isClose(loop.frameTime(elapsed: 4_000_001), 1, 1e-6))
        #expect(loop.restTime == 3)
    }

    @Test func oneShotHoldsItsLastFrame() {
        let oneShot = HeroPlayback.once(duration: 2.2)
        #expect(isClose(oneShot.frameTime(elapsed: 1), 1))
        #expect(isClose(oneShot.frameTime(elapsed: 60), 2.2))
        #expect(oneShot.restTime == 2.2, "Reduce Motion shows the finished frame")
    }

    @Test func negativeElapsedClampsToStart() {
        #expect(loop.frameTime(elapsed: -1) == 0)
        #expect(HeroPlayback.once(duration: 1).frameTime(elapsed: -1) == 0)
    }

    // MARK: - Stage clock

    /// found → searching → found: the second "found" must play again, not
    /// open on its finished frame (the loop in between never "finishes").
    @Test func oneShotReplaysWhenItsStateComesBack() {
        let found = "found", searching = "searching"
        let foundPlayback = HeroPlayback.once(duration: 2.2)
        var clock = HeroClock()
        clock.start(key: found, at: t0)
        clock.finish(key: found)
        #expect(!clock.isTicking(key: found, canAnimate: true), "a rested one-shot stops the timeline")
        clock.start(key: searching, at: t0.addingTimeInterval(3))
        clock.start(key: found, at: t0.addingTimeInterval(5))
        #expect(clock.isTicking(key: found, canAnimate: true))
        #expect(isClose(clock.frameTime(playback: foundPlayback, key: found, canAnimate: true, now: t0.addingTimeInterval(5.5)), 0.5))
    }

    /// Between a state change and its clock starting, show the new picture's
    /// first frame, not a flash of its last.
    @Test func newStateOpensOnItsFirstFrame() {
        var clock = HeroClock()
        clock.start(key: "searching", at: t0)
        #expect(clock.frameTime(playback: .once(duration: 2), key: "found", canAnimate: true, now: t0) == 0)
    }

    @Test func staleFinishIsIgnored() {
        var clock = HeroClock()
        clock.start(key: "teach", at: t0)
        clock.finish(key: "sent")
        #expect(clock.isTicking(key: "teach", canAnimate: true))
    }

    @Test func pausedShowsRestFrameAndStopsTicking() {
        var clock = HeroClock()
        clock.start(key: 0, at: t0)
        #expect(!clock.isTicking(key: 0, canAnimate: false))
        #expect(clock.frameTime(playback: loop, key: 0, canAnimate: false, now: t0.addingTimeInterval(1)) == 3)
    }

    /// Resuming a loop continues from the rest frame it showed while paused.
    @Test func loopResumesFromItsRestFrame() {
        var clock = HeroClock()
        clock.start(key: 0, at: t0)
        let resumedAt = t0.addingTimeInterval(61.7)
        clock.resume(playback: loop, at: resumedAt)
        #expect(isClose(clock.frameTime(playback: loop, key: 0, canAnimate: true, now: resumedAt), 3))
        #expect(isClose(clock.frameTime(playback: loop, key: 0, canAnimate: true, now: resumedAt.addingTimeInterval(1.5)), 0.5))
    }

    @Test func resumeLeavesOneShotClockAlone() {
        var clock = HeroClock()
        let oneShot = HeroPlayback.once(duration: 2)
        clock.start(key: 0, at: t0)
        clock.resume(playback: oneShot, at: t0.addingTimeInterval(1))
        #expect(isClose(clock.frameTime(playback: oneShot, key: 0, canAnimate: true, now: t0.addingTimeInterval(1.5)), 1.5))
    }

    // MARK: - Curves

    @Test func progressIsClampedAndEased() {
        #expect(HeroCurve.progress(0.1, start: 0.3, duration: 0.5) == 0)
        #expect(HeroCurve.progress(2, start: 0.3, duration: 0.5) == 1)
        #expect(isClose(HeroCurve.progress(0.55, start: 0.3, duration: 0.5), 0.5))
        #expect(isClose(HeroCurve.progress(0.55, start: 0.3, duration: 0.5, ease: .linear), 0.5))
        #expect(HeroCurve.progress(1, start: 1, duration: 0) == 1, "zero-length beat jumps")
    }

    @Test func springOvershootsThenSettles() {
        let peak = (1...99).map { HeroCurve.progress(Double($0) / 100, start: 0, duration: 1, ease: .spring) }.max() ?? 0
        #expect(peak > 1)
        #expect(isClose(HeroCurve.progress(1, start: 0, duration: 1, ease: .spring), 1))
    }

    @Test func loopFadeDipsAtTheSeamOnly() {
        #expect(HeroCurve.loopFade(0, playback: loop) == 0)
        #expect(HeroCurve.loopFade(2, playback: loop) == 1)
        #expect(isClose(HeroCurve.loopFade(4, playback: loop), 0))
        #expect(HeroCurve.loopFade(0, playback: .once(duration: 1)) == 1, "one-shots never fade")
    }
}
