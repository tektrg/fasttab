import AppKit
import Foundation
import Testing
@testable import AgentBar

/// The message card with a `/compact` draft: what reaches the dashboard, and the progress the card
/// follows (poll per `ManualTicker` tick, stop on close, resume on open). Fake source only.
@MainActor
struct CompactCardTests {
    private typealias F = CompactFixtures

    private struct Rig {
        let model: MessageCardModel
        let source: CompactFakeSource
        let ticker: ManualTicker
    }

    /// The follower's clock (epoch seconds) at every press.
    static let pressTime = 1_000.0

    private func makeRig() -> Rig {
        let source = CompactFakeSource()
        let ticker = ManualTicker()
        let pressTime = Self.pressTime
        let model = MessageCardModel(
            loadSessionContext: { _ in SessionContext(latestMessage: "Done.", planFile: nil) },
            makeCompactFollower: { CompactJobFollower(rowId: $0, source: $1, sleep: ticker.sleep, now: { pressTime }) }
        )
        model.statusSource = source
        return Rig(model: model, source: source, ticker: ticker)
    }

    private func agent() -> AgentSnapshot {
        var agent = AgentListFixtures.agent("a", label: "agent a", project: "proj", section: .working)
        agent.sessionId = "session-1"
        agent.rowId = "row-a"
        return agent
    }

    /// Opens the card and lets its resume read land.
    private func open(_ rig: Rig) async {
        #expect(rig.model.open(agent()))
        await waitUntil { rig.source.rowReads.count == 1 }
        await settleTasks()
    }

    /// One poll: wait for the loop to sleep, wake it, wait for its read.
    private func poll(_ rig: Rig) async {
        let reads = rig.source.idReads.count
        await waitUntil { rig.ticker.waiting == 1 }
        rig.ticker.tick()
        await waitUntil { rig.source.idReads.count == reads + 1 }
        await settleTasks()
    }

    /// Ends a test with nothing left hanging: the card closed, sleepers woken, pending starts answered.
    private func finish(_ rig: Rig) async {
        rig.model.close()
        rig.ticker.tick()
        while rig.source.pendingStartCount > 0 { rig.source.replyStart(.failed("test over")) }
        await settleTasks()
    }

    // MARK: - Where the draft goes

    @Test func aCompactDraftStartsTheCompactJobWithItsFields() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact keep the plan\nthen run the tests\nand push")
        #expect(rig.model.card?.sendTitle == "Compact")
        #expect(rig.model.canSend)
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.source.starts == [.init(rowId: "row-a", actor: "po", instructions: "keep the plan", followUp: "then run the tests and push")])
        #expect(rig.source.messages.isEmpty)
        #expect(rig.model.compactProgress == .starting)
        #expect(!rig.model.canSend)   // single-flight while it starts
        rig.model.pressSend()
        await settleTasks()
        #expect(rig.source.starts.count == 1)
        await finish(rig)
    }

    @Test func aBareCompactSendsNoOptionalFields() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.source.starts == [.init(rowId: "row-a", actor: "po", instructions: nil, followUp: nil)])
        await finish(rig)
    }

    @Test func aPlainDraftStillGoesToTheMessageSend() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("please continue\n/compact later")
        rig.model.pressSend()
        await waitUntil { !rig.source.messages.isEmpty }
        #expect(rig.source.messages == ["please continue /compact later"])
        #expect(rig.source.starts.isEmpty)
        #expect(rig.model.compactProgress == .idle)
    }

    @Test func compactWithImagesIsRefusedInline() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: 40, height: 20))
        image.addRepresentation(rep)
        rig.model.addImages([image])
        #expect(rig.model.card?.images.count == 1)
        #expect(rig.model.card?.draftHint == MessageCard.compactWithImagesHint)
        #expect(!rig.model.canSend)
    }

    // MARK: - Following the job

    @Test func theCardFollowsTheJobThroughEveryStateToDone() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact\nthen this")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [
            .job(F.job(.switchingModel, rowId: "row-a")),
            .job(F.job(.compacting, rowId: "row-a")),
            .job(F.job(.restoringModel, rowId: "row-a")),
            .job(F.job(.sendingFollowUp, rowId: "row-a")),
            .job(F.job(.done, rowId: "row-a", followUpSent: true)),
        ])
        rig.source.replyStart(.started(F.job(.waitingIdle, rowId: "row-a")))
        await waitUntil { rig.model.compactProgress.line == "Waiting for agent…" }
        #expect(rig.model.card?.draft == "")   // the text is in the job now
        var lines: [String?] = []
        for _ in 0..<5 {
            await poll(rig)
            lines.append(rig.model.compactProgress.line)
        }
        #expect(lines == ["Switching to Sonnet…", "Compacting…", "Restoring Opus 5.5…", "Sending your message…", "Compacted ✓"])
        #expect(rig.source.idReads == Array(repeating: "job-1", count: 5))
        await settleTasks()
        #expect(rig.ticker.waiting == 0)   // the loop ended with the job
        #expect(rig.ticker.sleepCount == 5)
        #expect(rig.model.canSend == false)   // empty draft
        rig.model.setDraft("/compact")
        #expect(rig.model.canSend)   // a finished job never blocks the next
    }

    @Test func aFailedJobSaysWhyAndThatTheMessageStillWent() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact\nthen this")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.job(F.job(.failed, rowId: "row-a", followUpSent: true, error: "compact did not finish"))])
        rig.source.replyStart(.started(F.job(.compacting, rowId: "row-a")))
        await poll(rig)
        #expect(rig.model.compactProgress.line == "Compact failed: compact did not finish")
        #expect(rig.model.compactProgress.detail == "Your message was still sent")
        #expect(rig.model.compactProgress.isFailure)
    }

    @Test func aSkippedSwitchIsShown() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.job(F.job(.done, rowId: "row-a", switchSkipped: true, skipReason: "already on Sonnet"))])
        rig.source.replyStart(.started(F.job(.compacting, rowId: "row-a", switchSkipped: true, skipReason: "already on Sonnet")))
        await waitUntil { rig.model.compactProgress.detail != nil }
        #expect(rig.model.compactProgress.detail == "Model not switched: already on Sonnet")
        await poll(rig)
        #expect(rig.model.compactProgress.line == "Compacted ✓")
        #expect(rig.model.compactProgress.detail == "Model not switched: already on Sonnet")
    }

    @Test func a409AdoptsTheRunningJobAndKeepsTheDraft() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact mine")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.job(F.job(.done, id: "web-job", rowId: "row-a"))])
        rig.source.replyStart(.alreadyRunning(F.job(.compacting, id: "web-job", rowId: "row-a")))
        await waitUntil { rig.model.compactProgress.runningJobId == "web-job" }
        #expect(rig.model.compactProgress.detail == CompactProgress.adoptedNote)
        #expect(rig.model.card?.draft == "/compact mine")
        #expect(!rig.model.canSend)
        await poll(rig)
        #expect(rig.source.idReads == ["web-job"])
        #expect(rig.model.compactProgress.line == "Compacted ✓")
    }

    @Test func aRefusedStartShowsWhyAndAllowsAnotherTry() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.replyStart(.failed("row is not a Claude pane"))
        await waitUntil { rig.model.compactProgress == .startFailed("row is not a Claude pane") }
        #expect(rig.model.card?.draft == "/compact")
        #expect(rig.model.canSend)
        #expect(rig.ticker.sleepCount == 0)
    }

    @Test func anUncertainStartLooksTheJobUpInsteadOfPostingAgain() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.rowRead = .job(F.job(.compacting, rowId: "row-a"))
        rig.source.replyStart(.uncertain("took too long"))
        await waitUntil { rig.model.compactProgress.runningJobId == "job-1" }
        #expect(rig.source.rowReads.count == 2)
        #expect(rig.source.starts.count == 1)
        await finish(rig)
    }

    /// QA fix: a timed-out start whose job already FINISHED (made since the press) shows that job's
    /// result instead of "not started", and the draft goes — pressing again would send the
    /// follow-up a second time.
    @Test func anUncertainStartAdoptsAFinishedJobMadeSinceThePress() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact\nthen push")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.rowRead = .job(F.job(.done, rowId: "row-a", followUpSent: true, createdAt: Self.pressTime + 2))
        rig.source.replyStart(.uncertain("took too long"))
        await waitUntil { rig.model.compactProgress.line == "Compacted ✓" }
        #expect(rig.source.starts.count == 1)
        #expect(rig.model.card?.draft == "")   // the text was used: nothing left to press again
        #expect(!rig.model.canSend)
        #expect(rig.ticker.sleepCount == 0)   // a finished job is not polled
    }

    @Test func anUncertainStartIgnoresAFinishedJobFromBeforeThePress() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.rowRead = .job(F.job(.done, rowId: "row-a", createdAt: Self.pressTime - 600))
        rig.source.replyStart(.uncertain("took too long"))
        await waitUntil { rig.model.compactProgress == .startFailed("took too long") }
        #expect(rig.model.card?.draft == "/compact")
        #expect(rig.model.canSend)
    }

    /// The dashboard reports `followUpSent=false`: the card says so in capitals and puts the queued
    /// text back in the (empty) box so the user can send it again.
    @Test func aQueuedMessageNotSentIsSaidAndPutBackInTheBox() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact\nthen run the tests")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.job(F.job(.failed, rowId: "row-a", modelRestored: false, followUpSent: false, error: "dashboard restarted"))])
        rig.source.replyStart(.started(F.job(.compacting, rowId: "row-a")))
        await waitUntil { rig.model.card?.draft == "" }
        await poll(rig)
        #expect(rig.model.compactProgress.line == "Compact failed: dashboard restarted")
        #expect(rig.model.card?.draft == "then run the tests")
        let detail = rig.model.compactDetail ?? ""
        #expect(detail.contains("Model NOT restored: still on Sonnet"))
        #expect(detail.contains("Your queued message was NOT sent — it's back in the box to send again"))
        #expect(rig.model.card?.compactDraft == nil)   // a plain message now: Send types it
    }

    @Test func textTypedDuringTheJobIsNeverReplacedByTheUnsentMessage() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact\nqueued")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.job(F.job(.done, rowId: "row-a", followUpSent: false))])
        rig.source.replyStart(.started(F.job(.compacting, rowId: "row-a")))
        await waitUntil { rig.model.card?.draft == "" }
        rig.model.setDraft("something new")
        await poll(rig)
        #expect(rig.model.card?.draft == "something new")
        #expect(rig.model.compactDetail == "Your queued message was NOT sent")
    }

    @Test func closingTheCardStopsPolling() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [], then: .job(F.job(.compacting, rowId: "row-a")))
        rig.source.replyStart(.started(F.job(.compacting, rowId: "row-a")))
        await poll(rig)
        await waitUntil { rig.ticker.waiting == 1 }
        rig.model.close()
        rig.ticker.tick()
        await settleTasks()
        #expect(rig.source.idReads.count == 1)   // the wake-up after close read nothing
        #expect(rig.ticker.waiting == 0)
        #expect(rig.model.compactProgress == .idle)
    }

    @Test func aStartReplyAfterTheCardClosedIsDropped() async {
        let rig = makeRig()
        await open(rig)
        rig.model.setDraft("/compact")
        rig.model.pressSend()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.model.handleEscape()
        #expect(rig.model.isOpen)   // Esc waits while the compact starts
        rig.model.close()
        rig.source.replyStart(.started(F.job(.compacting, rowId: "row-a")))
        await settleTasks()
        #expect(rig.ticker.sleepCount == 0 && rig.source.idReads.isEmpty)
    }

    @Test func openingTheCardResumesARunningJob() async {
        let rig = makeRig()
        rig.source.rowRead = .job(F.job(.compacting, id: "from-web", rowId: "row-a"))
        rig.source.script(idReads: [.job(F.job(.done, id: "from-web", rowId: "row-a"))])
        await open(rig)
        #expect(rig.source.rowReads == ["row-a"])
        #expect(rig.model.compactProgress.line == "Compacting…")
        rig.model.setDraft("/compact")
        #expect(!rig.model.canSend)   // one runs already
        await poll(rig)
        #expect(rig.source.idReads == ["from-web"])
        #expect(rig.model.compactProgress.line == "Compacted ✓")
    }

    @Test func openingTheCardShowsARecentFinishedJobWithoutPolling() async {
        let rig = makeRig()
        rig.source.rowRead = .job(F.job(.failed, rowId: "row-a", error: "restore failed"))
        await open(rig)
        #expect(rig.model.compactProgress.line == "Compact failed: restore failed")
        await settleTasks()
        #expect(rig.ticker.sleepCount == 0)
    }

    @Test func reopeningAfterCloseResumesWhereTheJobIs() async {
        let rig = makeRig()
        await open(rig)
        rig.model.close()
        rig.source.rowRead = .job(F.job(.restoringModel, rowId: "row-a"))
        #expect(rig.model.open(agent()))
        await waitUntil { rig.model.compactProgress.line == "Restoring Opus 5.5…" }
        #expect(rig.source.rowReads.count == 2)
        await finish(rig)
    }

    @Test func anInboxRowNeverAsksAboutCompactJobs() async {
        let rig = makeRig()
        #expect(rig.model.open(InboxFixtures.inboxAgent()))
        await settleTasks()
        #expect(rig.source.rowReads.isEmpty)
        rig.model.setDraft("/compact")
        #expect(rig.model.card?.compactDraft == nil)
        #expect(!rig.model.canSend)   // refused like any slash command on that route
    }
}
