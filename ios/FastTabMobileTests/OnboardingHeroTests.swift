import XCTest
import HeroMotion
@testable import FastTabMobile

/// Onboarding hero animation logic: which picture each step's live state shows,
/// and that each looping picture rests on a fully visible frame.
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

    /// The Mac is usually found while the user is off at their Mac with the
    /// app in the background: its one-shot beat must wait and play on return,
    /// not run out unseen (the stage feeds `HeroClock.sync` its pause state).
    func testFoundBeatThatLandsInTheBackgroundPlaysOnReturn() {
        let found = ConnectHeroState.found.playback
        let arrived = Date()
        var clock = HeroClock()
        XCTAssertNil(clock.sync(key: ConnectHeroState.found, playback: found, canAnimate: false, at: arrived))
        let back = arrived.addingTimeInterval(60)
        XCTAssertEqual(clock.sync(key: ConnectHeroState.found, playback: found, canAnimate: true, at: back), found.oneShotDuration)
        XCTAssertEqual(clock.frameTime(playback: found, key: ConnectHeroState.found, canAnimate: true, now: back), 0, "plays from its first frame")
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

    // MARK: - Rest frames
    //
    // The clock and curves themselves are tested once, in the shared
    // `HeroMotion` package (`Tests/HeroMotionTests`).

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
}
