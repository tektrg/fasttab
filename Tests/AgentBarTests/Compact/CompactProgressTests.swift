import Testing
@testable import AgentBar

/// The pure `/compact` progress machine: every state, its words, and the events it must ignore.
struct CompactProgressTests {
    private typealias P = CompactProgress
    private typealias F = CompactFixtures

    private func tracking(_ job: CompactJob, adopted: Bool = false) -> P {
        .tracking(P.Tracking(job: job, adopted: adopted))
    }

    // MARK: - Words for every job state

    @Test func everyRunningStateHasItsLine() {
        #expect(F.job(.waitingIdle).progressLine == "Waiting for agent…")
        #expect(F.job(.switchingModel).progressLine == "Switching to Sonnet…")
        #expect(F.job(.compacting).progressLine == "Compacting…")
        #expect(F.job(.restoringModel).progressLine == "Restoring Opus 5.5…")
        #expect(F.job(.restoringModel, originalModel: nil).progressLine == "Restoring the model…")
        #expect(F.job(.sendingFollowUp).progressLine == "Sending your message…")
        #expect(F.job(.unknown("newStep")).progressLine == "Compacting…")
    }

    @Test func doneAndFailedHaveTheirLines() {
        #expect(F.job(.done).progressLine == "Compacted ✓")
        #expect(F.job(.failed, error: "compact did not finish").progressLine == "Compact failed: compact did not finish")
        #expect(F.job(.failed).progressLine == "Compact failed: no reason given")
    }

    @Test func aSkippedSwitchIsMentionedWithItsReason() {
        let job = F.job(.done, switchSkipped: true, skipReason: "already on Sonnet")
        #expect(job.detailLine == "Model not switched: already on Sonnet")
        #expect(F.job(.compacting, switchSkipped: true).detailLine == "Model not switched")
    }

    @Test func aFollowUpSentAfterAFailureIsMentioned() {
        #expect(F.job(.failed, followUpSent: true, error: "x").detailLine == "Your message was still sent")
        #expect(F.job(.failed, error: "x").detailLine == nil)
        #expect(F.job(.done, followUpSent: true).detailLine == nil)
    }

    /// The dashboard sets `followUpSent=false` whenever a queued message existed but did not go
    /// (also after a dashboard restart), whatever the end state: always said, in capitals.
    @Test func aQueuedMessageNotSentIsSaidPlainlyInEveryEndState() {
        #expect(F.job(.failed, followUpSent: false, error: "x").detailLine == "Your queued message was NOT sent")
        #expect(F.job(.done, followUpSent: false).detailLine == "Your queued message was NOT sent")
    }

    @Test func aModelNotRestoredIsSaidPlainly() {
        #expect(F.job(.failed, modelRestored: false, error: "x").detailLine
            == "Model NOT restored: still on Sonnet (was Opus 5.5 — switch back with /model)")
        #expect(F.job(.failed, originalModel: nil, modelRestored: false, followUpSent: false, error: "x").detailLine
            == "Model NOT restored: still on Sonnet — switch back with /model · Your queued message was NOT sent")
        #expect(F.job(.done, modelRestored: true).detailLine == nil)
    }

    // MARK: - Transitions

    @Test func aStartGoesStartingThenTracking() {
        var progress = P.idle
        do { let accepted = progress.apply(.startPressed); #expect(accepted == true) }
        #expect(progress == .starting && progress.isBusy && progress.line == "Starting compact…")
        do { let accepted = progress.apply(.startReplied(.started(F.job(.waitingIdle)))); #expect(accepted == true) }
        #expect(progress == tracking(F.job(.waitingIdle)))
        #expect(progress.runningJobId == "job-1" && progress.isBusy)
    }

    @Test func pollsWalkEveryStateToDone() {
        var progress = tracking(F.job(.waitingIdle))
        for state in [CompactJob.State.switchingModel, .compacting, .restoringModel, .sendingFollowUp] {
            do { let accepted = progress.apply(.polled(.job(F.job(state)))); #expect(accepted == true) }
            #expect(progress.line == F.job(state).progressLine)
            #expect(progress.runningJobId == "job-1")
        }
        do { let accepted = progress.apply(.polled(.job(F.job(.done)))); #expect(accepted == true) }
        #expect(progress.line == "Compacted ✓" && !progress.isBusy && !progress.isFailure)
        #expect(progress.runningJobId == nil)
        // A late poll after the end changes nothing.
        do { let accepted = progress.apply(.polled(.job(F.job(.compacting)))); #expect(accepted == false) }
    }

    @Test func aFailedJobEndsAsAFailure() {
        var progress = tracking(F.job(.compacting))
        progress.apply(.polled(.job(F.job(.failed, followUpSent: true, error: "compact timed out"))))
        #expect(progress.isFailure && !progress.isBusy)
        #expect(progress.line == "Compact failed: compact timed out")
        #expect(progress.detail == "Your message was still sent")
    }

    @Test func singleFlightRefusesASecondStartWhileStartingOrRunning() {
        var progress = P.starting
        do { let accepted = progress.apply(.startPressed); #expect(accepted == false) }
        progress = tracking(F.job(.compacting))
        do { let accepted = progress.apply(.startPressed); #expect(accepted == false) }
        progress = tracking(F.job(.done))
        do { let accepted = progress.apply(.startPressed); #expect(accepted == true) }   // a finished one never blocks the next
        progress = .startFailed("x")
        do { let accepted = progress.apply(.startPressed); #expect(accepted == true) }
    }

    @Test func a409AdoptsTheRunningJobAndSaysSo() {
        var progress = P.starting
        progress.apply(.startReplied(.alreadyRunning(F.job(.compacting, id: "older"))))
        #expect(progress == tracking(F.job(.compacting, id: "older"), adopted: true))
        #expect(progress.runningJobId == "older")
        #expect(progress.detail == P.adoptedNote)
    }

    @Test func aRefusedStartIsAFailureState() {
        var progress = P.starting
        progress.apply(.startReplied(.failed("row not a Claude pane")))
        #expect(progress == .startFailed("row not a Claude pane") && progress.isFailure && !progress.isBusy)
        #expect(progress.line == "Compact not started: row not a Claude pane")
        #expect(progress.isSettled)
    }

    // MARK: - Uncertain start (timeout): look the row up, adopt this press's job even if finished

    private let pressedAt = 1_000.0

    private func lookingUp() -> P {
        var progress = P.starting
        progress.apply(.startReplied(.uncertain("took too long"), pressedAt: pressedAt))
        return progress
    }

    @Test func anUncertainStartLooksUpAndStaysBusy() {
        let progress = lookingUp()
        #expect(progress == .lookingUp(reason: "took too long", notBefore: pressedAt - P.clockSkewSeconds))
        #expect(progress.isBusy && !progress.isSettled && !progress.isFailure)
        #expect(progress.line == "May have started: checking…")
        var again = progress
        do { let accepted = again.apply(.startPressed); #expect(accepted == false) }   // no second POST meanwhile
    }

    @Test func theLookupFindsTheRunningJobItMade() {
        var progress = lookingUp()
        do { let accepted = progress.apply(.resumed(.job(F.job(.waitingIdle, createdAt: pressedAt + 1)))); #expect(accepted == true) }
        #expect(progress == tracking(F.job(.waitingIdle, createdAt: pressedAt + 1)))
        #expect(progress.runningJobId == "job-1")
    }

    /// The fix for "follow-up sent twice": a job that already FINISHED but was made since the press
    /// (within the clock-skew margin) is this press's job: its result shows, not "not started".
    @Test func theLookupAdoptsAFinishedJobMadeSinceThePress() {
        var progress = lookingUp()
        let job = F.job(.done, followUpSent: true, createdAt: pressedAt - 4)   // dashboard clock 4s behind
        do { let accepted = progress.apply(.resumed(.job(job))); #expect(accepted == true) }
        #expect(progress == tracking(job))
        #expect(progress.line == "Compacted ✓" && progress.isSettled && !progress.isBusy)
    }

    @Test func theLookupIgnoresAFinishedJobFromBeforeThePress() {
        var progress = lookingUp()
        progress.apply(.resumed(.job(F.job(.done, createdAt: pressedAt - 60))))
        #expect(progress == .startFailed("took too long"))
        progress = lookingUp()
        progress.apply(.resumed(.job(F.job(.done))))   // no createdAt: can't be told apart, not adopted
        #expect(progress == .startFailed("took too long"))
    }

    @Test func anOlderRunningJobFoundByTheLookupIsShownAsSomeoneElses() {
        var progress = lookingUp()
        progress.apply(.resumed(.job(F.job(.compacting, createdAt: pressedAt - 60))))
        #expect(progress == tracking(F.job(.compacting, createdAt: pressedAt - 60), adopted: true))
        #expect(progress.detail == P.adoptedNote)
    }

    @Test func theLookupFindingNothingIsNotStarted() {
        var progress = lookingUp()
        progress.apply(.resumed(.none))
        #expect(progress == .startFailed("took too long") && progress.isSettled)
        progress = lookingUp()
        progress.apply(.resumed(.failed("down")))
        #expect(progress == .startFailed("took too long"))
    }

    // MARK: - Footer words for a compact with no card

    @Test func aCleanDoneNeedsNoNotice() {
        #expect(tracking(F.job(.done)).headlessNotice(label: "w", followUp: nil) == nil)
        #expect(tracking(F.job(.done, followUpSent: true)).headlessNotice(label: "w", followUp: "go on") == nil)
        #expect(tracking(F.job(.done, switchSkipped: true, skipReason: "already on Sonnet")).headlessNotice(label: "w", followUp: nil) == nil)
        #expect(tracking(F.job(.compacting)).headlessNotice(label: "w", followUp: nil) == nil)   // still running
    }

    @Test func aFailedJobNoticeSaysWhyAndRepeatsAnUnsentMessage() {
        let failed = tracking(F.job(.failed, modelRestored: false, followUpSent: false, error: "compact timed out"))
        #expect(failed.headlessNotice(label: "w", followUp: "run the tests")
            == "w: Compact failed: compact timed out · Model NOT restored: still on Sonnet (was Opus 5.5 — switch back with /model) · Your queued message was NOT sent: \u{201C}run the tests\u{201D}")
        #expect(P.startFailed("row is not live").headlessNotice(label: "w", followUp: nil) == "Couldn't compact w: row is not live")
        #expect(P.lostTrack(F.job(.compacting), "down").headlessNotice(label: "w", followUp: nil) == "Lost track of w's compact: down. It may still be running.")
    }

    @Test func anAdoptedJobNoticeSaysTheTypedMessageDidNotGo() {
        let adopted = tracking(F.job(.done), adopted: true)
        #expect(adopted.headlessNotice(label: "w", followUp: nil) == nil)   // a bare compact: someone else's did the job
        #expect(adopted.headlessNotice(label: "w", followUp: "go on")
            == "w: Compacted ✓ · \(P.adoptedHeadlessNote) · Your queued message was NOT sent: \u{201C}go on\u{201D}")
    }

    @Test func afterAFailedStartAFinishedJobIsOldNews() {
        var progress = P.startFailed("x")
        do { let accepted = progress.apply(.resumed(.job(F.job(.done)))); #expect(accepted == false) }
        #expect(progress == .startFailed("x"))
    }

    @Test func resumeOnOpenShowsARunningOrRecentJob() {
        var progress = P.idle
        do { let accepted = progress.apply(.resumed(.job(F.job(.compacting)))); #expect(accepted == true) }
        #expect(progress.runningJobId == "job-1")
        progress = .idle
        progress.apply(.resumed(.job(F.job(.done))))
        #expect(progress.line == "Compacted ✓" && progress.runningJobId == nil)
        progress = .idle
        do { let accepted = progress.apply(.resumed(.none)); #expect(accepted == false) }
        do { let accepted = progress.apply(.resumed(.failed("down"))); #expect(accepted == false) }
        #expect(progress == .idle && progress.line == nil)
    }

    @Test func aResumeNeverOverridesAStartInProgress() {
        var progress = P.starting
        do { let accepted = progress.apply(.resumed(.job(F.job(.done, id: "old")))); #expect(accepted == false) }
        #expect(progress == .starting)
        progress = tracking(F.job(.compacting))
        do { let accepted = progress.apply(.resumed(.job(F.job(.done, id: "old")))); #expect(accepted == false) }
        #expect(progress.runningJobId == "job-1")
    }

    @Test func aStartReplyOutsideStartingIsIgnored() {
        var progress = P.idle
        do { let accepted = progress.apply(.startReplied(.started(F.job(.compacting)))); #expect(accepted == false) }
        #expect(progress == .idle)
    }

    @Test func aPollForAnotherJobIsIgnored() {
        var progress = tracking(F.job(.compacting))
        do { let accepted = progress.apply(.polled(.job(F.job(.done, id: "other")))); #expect(accepted == false) }
        #expect(progress == tracking(F.job(.compacting)))
    }

    @Test func pollFailuresAreToleratedThenLoseTrack() {
        var progress = tracking(F.job(.compacting))
        for _ in 1..<P.maxFailedPolls { progress.apply(.polled(.failed("down"))) }
        #expect(progress.runningJobId == "job-1")
        // A good read resets the count.
        progress.apply(.polled(.job(F.job(.compacting))))
        for _ in 1..<P.maxFailedPolls { progress.apply(.polled(.failed("down"))) }
        #expect(progress.runningJobId == "job-1")
        progress.apply(.polled(.failed("down")))
        #expect(progress == .lostTrack(F.job(.compacting), "down"))
        #expect(progress.isFailure && !progress.isBusy && progress.line?.contains("may still be running") == true)
    }

    /// QA #2: a poll that says "unknown job" (dashboard restarted?) looks the row up once first.
    @Test func aJobTheDashboardForgotIsLookedUpByRowBeforeLosingTrack() {
        var progress = tracking(F.job(.compacting))
        progress.apply(.polled(.none))
        #expect(progress == .relocating(P.Tracking(job: F.job(.compacting))))
        #expect(progress.isBusy && !progress.isSettled && !progress.isFailure && progress.runningJobId == nil)
        #expect(progress.line == "Compacting…" && progress.headlessNotice(label: "w", followUp: nil) == nil)
        do { let accepted = progress.apply(.startPressed); #expect(accepted == false) }
        progress.apply(.resumed(.none))
        #expect(progress == .lostTrack(F.job(.compacting), P.goneReason))
    }

    @Test func theRowLookUpFindingTheSameJobGoesOnFollowingIt() {
        var progress = tracking(F.job(.compacting), adopted: true)
        progress.apply(.polled(.none))
        progress.apply(.resumed(.job(F.job(.restoringModel))))
        #expect(progress == tracking(F.job(.restoringModel), adopted: true))
        #expect(progress.runningJobId == "job-1")
    }

    @Test func theRowLookUpFindingAnotherJobOrFailingLosesTrack() {
        var progress = tracking(F.job(.compacting))
        progress.apply(.polled(.none))
        progress.apply(.resumed(.job(F.job(.waitingIdle, id: "job-2"))))
        #expect(progress == .lostTrack(F.job(.compacting), P.goneReason))
        progress = tracking(F.job(.compacting))
        progress.apply(.polled(.none))
        progress.apply(.resumed(.failed("down")))
        #expect(progress == .lostTrack(F.job(.compacting), "down"))
    }

    // MARK: - Answers stay open except while the /model picker may be up (QA #2)

    @Test func onlyAJobInThePickerMayHaveThePickerOpen() {
        #expect(tracking(F.job(.switchingModel, inPicker: true)).mayHavePickerOpen)
        #expect(tracking(F.job(.restoringModel, inPicker: true)).mayHavePickerOpen)
        // The state alone says nothing: a restore can wait minutes for a busy agent, picker closed.
        for state: CompactJob.State in [.waitingIdle, .switchingModel, .compacting, .restoringModel, .sendingFollowUp, .done, .failed] {
            #expect(!tracking(F.job(state)).mayHavePickerOpen)
        }
        #expect(!tracking(F.job(.failed, inPicker: true)).mayHavePickerOpen)   // a finished job holds nothing open
        #expect(!P.starting.mayHavePickerOpen && !P.idle.mayHavePickerOpen)
    }
}
