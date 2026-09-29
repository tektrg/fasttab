import XCTest
@testable import FastTabMobile

/// Onboarding hero animation logic: which picture each step's live state shows,
/// and the clock (looping forever, one-shots resting on their last frame).
final class OnboardingHeroTests: XCTestCase {

    // MARK: - Connect Mac

    func testConnectHeroFollowsConnectionState() {
        XCTAssertEqual(ConnectHeroState(connection: .searching, macIsOffline: false), .searching)
        XCTAssertEqual(ConnectHeroState(connection: .notFound, macIsOffline: false), .notFound)
        XCTAssertEqual(ConnectHeroState(connection: .signedOut, macIsOffline: false), .accountBlocked)
        XCTAssertEqual(ConnectHeroState(connection: .restricted, macIsOffline: false), .accountBlocked)
        XCTAssertEqual(ConnectHeroState(connection: .found(macName: "Mac", tabCount: 3), macIsOffline: false), .found)
    }

    func testFoundButSilentMacShowsOfflinePicture() {
        XCTAssertEqual(ConnectHeroState(connection: .found(macName: "Mac", tabCount: 0), macIsOffline: true), .macOffline)
    }

    /// Only the search is a progress state; everything else plays once and rests.
    func testOnlySearchingLoops() {
        let allStates: [ConnectHeroState] = [.searching, .found, .macOffline, .notFound, .accountBlocked]
        for state in allStates {
            XCTAssertEqual(state.playback.oneShotDuration == nil, state == .searching, "\(state)")
        }
    }

    // MARK: - Send to Mac

    private func progress(_ stage: CommandProgress.Stage) -> CommandProgress {
        CommandProgress(stage: stage, symbolName: "circle", label: "label", tint: .blue, detail: nil)
    }

    func testSendHeroTeachesUntilTheTestLinkSucceeds() {
        XCTAssertEqual(SendHeroState(hasMac: true, tryProgress: nil), .teach)
        XCTAssertEqual(SendHeroState(hasMac: true, tryProgress: progress(.waitingForMac)), .teach)
        XCTAssertEqual(SendHeroState(hasMac: true, tryProgress: progress(.failed)), .teach)
        XCTAssertEqual(SendHeroState(hasMac: true, tryProgress: progress(.succeeded)), .sent)
    }

    func testNoMacOutranksEverything() {
        XCTAssertEqual(SendHeroState(hasMac: false, tryProgress: nil), .noMac)
        XCTAssertEqual(SendHeroState(hasMac: false, tryProgress: progress(.succeeded)), .noMac)
    }

    func testSentIsAOneShotAndTeachLoops() {
        XCTAssertNotNil(SendHeroState.sent.playback.oneShotDuration)
        XCTAssertNil(SendHeroState.teach.playback.oneShotDuration)
    }

    // MARK: - Try Reader

    func testReaderHeroShimmersOnlyWhilePreparing() {
        XCTAssertEqual(ReaderHeroState(isPreparing: true), .preparing)
        XCTAssertEqual(ReaderHeroState(isPreparing: false), .ready)
        XCTAssertNil(ReaderHeroState.preparing.playback.oneShotDuration)
        XCTAssertNil(ReaderHeroState.ready.playback.oneShotDuration)
    }

    // MARK: - Clock

    func testLoopRepeatsForever() {
        let playback = HeroPlayback.loop(period: 4, restAt: 3)
        XCTAssertEqual(playback.frameTime(elapsed: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(playback.frameTime(elapsed: 5), 1, accuracy: 1e-9)
        XCTAssertEqual(playback.frameTime(elapsed: 4_000_001), 1, accuracy: 1e-6)
        XCTAssertEqual(playback.restTime, 3)
    }

    func testOneShotHoldsItsLastFrame() {
        let playback = HeroPlayback.once(duration: 2.2)
        XCTAssertEqual(playback.frameTime(elapsed: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(playback.frameTime(elapsed: 60), 2.2, accuracy: 1e-9)
        XCTAssertEqual(playback.restTime, 2.2, "Reduce Motion shows the finished frame")
    }

    func testNegativeElapsedClampsToStart() {
        XCTAssertEqual(HeroPlayback.loop(period: 4, restAt: 3).frameTime(elapsed: -1), 0)
        XCTAssertEqual(HeroPlayback.once(duration: 1).frameTime(elapsed: -1), 0)
    }

    /// Every faded loop's rest frame must sit outside its fade window, or Reduce
    /// Motion would show a half-faded picture. (The radar and shimmer don't fade.)
    @MainActor
    func testRestFramesAreFullyVisible() {
        let fadedLoops: [HeroPlayback] = [
            OnboardingHeroWelcome.playback,
            ReaderHeroState.ready.playback,
            SendHeroState.teach.playback,
            OnboardingHeroDone.playback,
        ]
        for playback in fadedLoops {
            XCTAssertEqual(HeroCurve.loopFade(playback.restTime, playback: playback), 1, "\(playback)")
        }
    }

    // MARK: - Curves

    func testProgressIsClampedAndEased() {
        XCTAssertEqual(HeroCurve.progress(0.1, start: 0.3, duration: 0.5), 0)
        XCTAssertEqual(HeroCurve.progress(2, start: 0.3, duration: 0.5), 1)
        XCTAssertEqual(HeroCurve.progress(0.55, start: 0.3, duration: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HeroCurve.progress(0.55, start: 0.3, duration: 0.5, ease: .linear), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HeroCurve.progress(1, start: 1, duration: 0), 1, "zero-length beat jumps")
    }

    func testSpringOvershootsThenSettles() {
        let peak = (1...99).map { HeroCurve.progress(Double($0) / 100, start: 0, duration: 1, ease: .spring) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1)
        XCTAssertEqual(HeroCurve.progress(1, start: 0, duration: 1, ease: .spring), 1, accuracy: 1e-9)
    }

    func testLoopFadeDipsAtTheSeamOnly() {
        let playback = HeroPlayback.loop(period: 4, restAt: 3)
        XCTAssertEqual(HeroCurve.loopFade(0, playback: playback), 0)
        XCTAssertEqual(HeroCurve.loopFade(2, playback: playback), 1)
        XCTAssertEqual(HeroCurve.loopFade(4, playback: playback), 0, accuracy: 1e-9)
        XCTAssertEqual(HeroCurve.loopFade(0, playback: .once(duration: 1)), 1, "one-shots never fade")
    }
}
