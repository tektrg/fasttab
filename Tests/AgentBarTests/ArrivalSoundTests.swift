import Foundation
import Testing
@testable import AgentBar

/// Records what it was asked to play; no audio.
@MainActor
final class RecordingSoundPlayer: SoundPlayer {
    private(set) var played: [SoundChoice] = []
    func play(_ choice: SoundChoice) { played.append(choice) }
}

/// Which alert an arriving agent gets, including the wait for a late "blocked" classification.
struct ArrivalSoundPlannerTests {
    typealias A = AnswerFixtures
    private let t0 = AgentListFixtures.now
    private let hold = ArrivalSoundPlanner.holdSeconds

    private func idle(_ id: String = "a") -> AgentSnapshot { A.blockedAgent(id, blocker: nil) }
    private func blocked(_ id: String = "a", _ blocker: AgentBlocker = .permission) -> AgentSnapshot { A.blockedAgent(id, blocker: blocker) }

    @Test func anArrivalAlreadyBlockedPlaysTheAnswerAlertAtOnce() {
        for blocker in [AgentBlocker.permission, .questionLoading(nil), .questionNotAnswerable] {
            var planner = ArrivalSoundPlanner()
            let row = blocked("a", blocker)
            #expect(planner.observe(arrivals: [row], needsYou: [row], now: t0) == .needsAnswer)
            #expect(planner.nextDeadline == nil)
        }
    }

    @Test func anIdleArrivalIsHeldThenPlaysDone() {
        var planner = ArrivalSoundPlanner()
        #expect(planner.observe(arrivals: [idle()], needsYou: [idle()], now: t0) == nil)
        #expect(planner.nextDeadline == t0.addingTimeInterval(hold))
        #expect(planner.observe(arrivals: [], needsYou: [idle()], now: t0.addingTimeInterval(hold - 0.1)) == nil)
        #expect(planner.observe(arrivals: [], needsYou: [idle()], now: t0.addingTimeInterval(hold)) == .agentDone)
        #expect(planner.nextDeadline == nil)
    }

    @Test func aBlockerLearnedDuringTheHoldTurnsItIntoTheAnswerAlert() {
        var planner = ArrivalSoundPlanner()
        _ = planner.observe(arrivals: [idle()], needsYou: [idle()], now: t0)
        #expect(planner.observe(arrivals: [], needsYou: [blocked()], now: t0.addingTimeInterval(1)) == .needsAnswer)
        // ...and never a done after it.
        #expect(planner.observe(arrivals: [], needsYou: [blocked()], now: t0.addingTimeInterval(hold + 1)) == nil)
    }

    @Test func aBlockerLearnedAfterTheHoldIsTooLate() {
        var planner = ArrivalSoundPlanner()
        _ = planner.observe(arrivals: [idle()], needsYou: [idle()], now: t0)
        #expect(planner.observe(arrivals: [], needsYou: [idle()], now: t0.addingTimeInterval(hold)) == .agentDone)
        #expect(planner.observe(arrivals: [], needsYou: [blocked()], now: t0.addingTimeInterval(hold + 5)) == nil)
    }

    @Test func anAgentThatLeavesDuringTheHoldPlaysNothing() {
        var planner = ArrivalSoundPlanner()
        _ = planner.observe(arrivals: [idle()], needsYou: [idle()], now: t0)
        #expect(planner.observe(arrivals: [], needsYou: [], now: t0.addingTimeInterval(1)) == nil)
        #expect(planner.observe(arrivals: [], needsYou: [], now: t0.addingTimeInterval(hold + 1)) == nil)
        #expect(planner.nextDeadline == nil)
    }

    @Test func aBatchWithBothKindsPlaysOnlyTheAnswerAlert() {
        var planner = ArrivalSoundPlanner()
        let rows = [idle("a"), blocked("b")]
        #expect(planner.observe(arrivals: rows, needsYou: rows, now: t0) == .needsAnswer)
        // The idle one is still held, and settles later with its own single sound.
        #expect(planner.observe(arrivals: [], needsYou: rows, now: t0.addingTimeInterval(hold)) == .agentDone)
    }

    @Test func severalIdleArrivalsPlayOneDone() {
        var planner = ArrivalSoundPlanner()
        let rows = [idle("a"), idle("b")]
        _ = planner.observe(arrivals: rows, needsYou: rows, now: t0)
        #expect(planner.observe(arrivals: [], needsYou: rows, now: t0.addingTimeInterval(hold)) == .agentDone)
        #expect(planner.observe(arrivals: [], needsYou: rows, now: t0.addingTimeInterval(hold * 2)) == nil)
    }

    @Test func agentsAlreadyWaitingPlayNothing() {
        var planner = ArrivalSoundPlanner()
        #expect(planner.observe(arrivals: [], needsYou: [idle(), blocked("b")], now: t0) == nil)
    }
}

/// The controller around the planner: the user's sound choices, the on/off switch, and the re-check timer.
@MainActor
struct ArrivalSoundControllerTests {
    typealias A = AnswerFixtures
    private let t0 = AgentListFixtures.now

    @MainActor private final class Rig {
        var clock = AgentListFixtures.now
        var settings = SoundSettings.standard
        let player = RecordingSoundPlayer()
        var timers: [(delay: TimeInterval, action: @MainActor () -> Void)] = []
        lazy var controller = ArrivalSoundController(
            settings: { [unowned self] in settings }, player: player, now: { [unowned self] in clock },
            schedule: { [unowned self] delay, action in timers.append((delay, action)) }
        )

        /// Moves the clock and fires the pending timer, as the real one would.
        func fireTimer(after seconds: TimeInterval) {
            clock = clock.addingTimeInterval(seconds)
            let due = timers
            timers = []
            for timer in due { timer.action() }
        }
    }

    private func idle(_ id: String = "a") -> AgentSnapshot { A.blockedAgent(id, blocker: nil) }
    private func blocked(_ id: String = "a") -> AgentSnapshot { A.blockedAgent(id, blocker: .permission) }

    @Test func aBlockedArrivalPlaysTheNeedsYouSoundImmediately() {
        let rig = Rig()
        rig.controller.observe(arrivals: [blocked()], needsYou: [blocked()])
        #expect(rig.player.played == [.funk])
    }

    @Test func anIdleArrivalPlaysTheDoneSoundWhenTheHoldTimerFires() {
        let rig = Rig()
        rig.controller.observe(arrivals: [idle()], needsYou: [idle()])
        #expect(rig.player.played.isEmpty)
        #expect(rig.timers.map(\.delay) == [ArrivalSoundPlanner.holdSeconds])
        rig.fireTimer(after: ArrivalSoundPlanner.holdSeconds)
        #expect(rig.player.played == [.glass])
        #expect(rig.timers.isEmpty)
    }

    @Test func aBlockerLearnedBeforeTheTimerPlaysOnlyTheNeedsYouSound() {
        let rig = Rig()
        rig.controller.observe(arrivals: [idle()], needsYou: [idle()])
        rig.clock = t0.addingTimeInterval(1)
        rig.controller.observe(arrivals: [], needsYou: [blocked()])
        rig.fireTimer(after: ArrivalSoundPlanner.holdSeconds)
        #expect(rig.player.played == [.funk])
    }

    @Test func anAgentLeavingBeforeTheTimerPlaysNothing() {
        let rig = Rig()
        rig.controller.observe(arrivals: [idle()], needsYou: [idle()])
        rig.controller.observe(arrivals: [], needsYou: [])
        rig.fireTimer(after: ArrivalSoundPlanner.holdSeconds)
        #expect(rig.player.played.isEmpty)
    }

    @Test func usesTheSoundsTheUserPickedAndNoneIsSilentChoice() {
        let rig = Rig()
        rig.settings.needsAnswer = .ping
        rig.settings.agentDone = .none
        rig.controller.observe(arrivals: [blocked("a")], needsYou: [blocked("a")])
        rig.controller.observe(arrivals: [idle("b")], needsYou: [blocked("a"), idle("b")])
        rig.fireTimer(after: ArrivalSoundPlanner.holdSeconds)
        // "None" is handed to the player, which plays nothing for it.
        #expect(rig.player.played == [.ping, .none])
    }

    @Test func nothingPlaysWhileSoundsAreOffAndOldArrivalsAreNotReplayedLater() {
        let rig = Rig()
        rig.settings.playsSounds = false
        rig.controller.observe(arrivals: [blocked()], needsYou: [blocked()])
        rig.controller.observe(arrivals: [idle("b")], needsYou: [blocked(), idle("b")])
        rig.fireTimer(after: ArrivalSoundPlanner.holdSeconds)
        rig.settings.playsSounds = true
        rig.controller.observe(arrivals: [], needsYou: [blocked(), idle("b")])
        #expect(rig.player.played.isEmpty)
    }
}

/// The model reports each reading of Needs you; the baseline reading has no arrivals.
@MainActor
struct NeedsYouReadingModelTests {
    typealias F = AgentListFixtures

    @Test func theBaselineReadingReportsNoArrivalsAndALaterOneDoes() {
        let defaults = makeScratchDefaults("readings")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults), now: { F.now }
        )
        var readings: [(arrivals: [String], needsYou: [String])] = []
        model.onNeedsYouReading = { readings.append(($0.map(\.id), $1?.map(\.id) ?? ["<down>"])) }
        model.receive(F.snapshot([F.agent("a")]))
        model.receive(F.snapshot([F.agent("a"), F.agent("b")]))
        model.receive(.down(reason: "unreachable", at: F.now))
        #expect(readings.map(\.arrivals) == [[], ["b"], []])
        #expect(readings.map(\.needsYou) == [["a"], ["a", "b"], ["<down>"]])
    }

    @Test func theArrivalIsReportedBeforeTheReadingSoTheCornerTabSeesThemInOrder() {
        let defaults = makeScratchDefaults("readings-order")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults), now: { F.now }
        )
        var order: [String] = []
        model.onNeedsYouArrival = { _ in order.append("arrival") }
        model.onNeedsYouReading = { _, _ in order.append("reading") }
        model.receive(F.snapshot([]))
        model.receive(F.snapshot([F.agent("a")]))
        #expect(order == ["reading", "arrival", "reading"])
    }

    @Test func aBlockerLearnedByTheProbeReachesTheReadingOnTheHeldAgent() {
        let defaults = makeScratchDefaults("readings-blocked")
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults), triageStore: TriageStore(defaults: defaults), now: { F.now }
        )
        var lastBlockers: [AgentBlocker?] = []
        model.onNeedsYouReading = { lastBlockers = ($1 ?? []).map(\.blocker) }
        model.receive(F.snapshot([]))
        model.receive(F.snapshot([AnswerFixtures.blockedAgent("a", blocker: .permission)]))
        #expect(lastBlockers == [.permission])
    }
}

struct SoundSettingsTests {
    @Test func defaultsAreOnWithFunkAndGlass() {
        let settings = SoundSettings.load(from: makeScratchDefaults())
        #expect(settings.playsSounds)
        #expect(settings.needsAnswer == .funk)
        #expect(settings.agentDone == .glass)
    }

    @Test func offersNoneAndTheFourteenSystemSounds() {
        #expect(SoundChoice.allCases.count == 15)
        #expect(SoundChoice.none.systemSoundName == nil)
        #expect(SoundChoice.glass.systemSoundName == "Glass")
    }

    @Test func aBogusStoredNameFallsBackToItsDefault() {
        let defaults = makeScratchDefaults()
        defaults.set("NotASound", forKey: SoundSettings.needsAnswerKey)
        defaults.set("Tink", forKey: SoundSettings.agentDoneKey)
        let settings = SoundSettings.load(from: defaults)
        #expect(settings.needsAnswer == .funk)
        #expect(settings.agentDone == .tink)
    }

    @MainActor @Test func changesPersistAcrossInstancesAndNoneSurvives() {
        let defaults = makeScratchDefaults()
        AgentBarSettings(defaults: defaults).updateSounds {
            $0.playsSounds = false
            $0.agentDone = .none
            $0.needsAnswer = .hero
        }
        let reloaded = AgentBarSettings(defaults: defaults).sounds
        #expect(!reloaded.playsSounds)
        #expect(reloaded.agentDone == .none)
        #expect(reloaded.needsAnswer == .hero)
    }
}
