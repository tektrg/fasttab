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
        #expect(F.job(.failed, followUpSent: false, error: "x").detailLine == "Your message was not sent")
        #expect(F.job(.failed, error: "x").detailLine == nil)
        #expect(F.job(.done, followUpSent: true).detailLine == nil)
    }

    @Test func aModelNotRestoredIsMentioned() {
        #expect(F.job(.failed, modelRestored: false, error: "x").detailLine == "Opus 5.5 was not restored — check /model in the terminal")
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

    @Test func aRefusedOrUncertainStartIsAFailureState() {
        var progress = P.starting
        progress.apply(.startReplied(.failed("row not a Claude pane")))
        #expect(progress == .startFailed("row not a Claude pane") && progress.isFailure && !progress.isBusy)
        #expect(progress.line == "Compact not started: row not a Claude pane")
        progress = .starting
        progress.apply(.startReplied(.uncertain("took too long")))
        #expect(progress == .startFailed("took too long"))
        // …then the lookup finds the job it made after all.
        do { let accepted = progress.apply(.resumed(.job(F.job(.waitingIdle)))); #expect(accepted == true) }
        #expect(progress.runningJobId == "job-1")
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

    @Test func aJobTheDashboardForgotLosesTrack() {
        var progress = tracking(F.job(.compacting))
        progress.apply(.polled(.none))
        #expect(progress == .lostTrack(F.job(.compacting), P.goneReason))
    }
}
