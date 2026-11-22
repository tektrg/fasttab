import Foundation
import Testing
@testable import AgentBar

/// Every compact in Agent Bar runs as the dashboard's compact job (owner decision 2026-11-22),
/// also with no card: a `/compact` typed in Tab-tag / Peek compose, the row's ⋯ Compact, and
/// Park. The row shows the job's progress, then "Compacted ✓"; anything else ends in the footer.
/// Rows the job can't serve (inbox, OpenCode/Codex, blocked) keep today's behaviour.
@MainActor @Suite(.serialized)
struct CompactPanelTests {
    private typealias F = AgentListFixtures
    private typealias J = CompactFixtures

    private struct Rig {
        let model: AgentPanelModel
        let source: CompactFakeSource
        let ticker: ManualTicker
    }

    private func makeRig(_ agents: [AgentSnapshot]) -> Rig {
        let defaults = makeScratchDefaults("compact-panel-\(UUID().uuidString)")
        let source = CompactFakeSource()
        let ticker = ManualTicker()
        let message = MessageCardModel(
            now: { F.now },
            loadSessionContext: { _ in SessionContext(latestMessage: "Done.", planFile: nil) },
            makeCompactFollower: { CompactJobFollower(rowId: $0, source: $1, sleep: ticker.sleep, now: { 1_000 }) }
        )
        let model = AgentPanelModel(
            store: FrecencyStore(defaults: defaults),
            triageStore: TriageStore(defaults: defaults),
            routedNoteStore: RoutedNoteStore(defaults: defaults),
            message: message,
            directSendRetryDelays: [0.01, 0.01],
            loadPeekMessage: { _ in SessionContext(latestMessage: "Done.", planFile: nil) },
            now: { F.now }
        )
        model.statusSource = source
        model.receive(F.snapshot(agents))
        return Rig(model: model, source: source, ticker: ticker)
    }

    private func working(_ id: String = "a", label: String = "worker-1") -> AgentSnapshot {
        F.agent(id, label: label, section: .working)
    }

    /// A Claude pane on another Mac: no hook data here, the dashboard types into it over ssh.
    private func remote(_ id: String = "r", section: AgentSection = .working) -> AgentSnapshot {
        var agent = F.agent(id, label: "air-worker", section: section, hasHookData: false, paneId: "air-m1:w8:\(id)")
        agent.messagesViaPane = true
        agent.agentKind = "claude"
        return agent
    }

    private func row(_ rig: Rig, _ id: String = "a") -> AgentSnapshot? {
        rig.model.snapshot?.agents.first { $0.id == id }
    }

    /// One poll: wait for the loop to sleep, wake it, wait for its read.
    private func poll(_ rig: Rig) async {
        let reads = rig.source.idReads.count
        await waitUntil { rig.ticker.waiting == 1 }
        rig.ticker.tick()
        await waitUntil { rig.source.idReads.count == reads + 1 }
        await settleTasks()
    }

    // MARK: - Compose

    @Test func aTabTaggedCompactStartsTheJobInsteadOfTypingIt() async throws {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.tagSelected()
        rig.model.query = "/compact keep the plan"
        rig.model.activateSelected()
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.source.starts == [.init(rowId: "a", actor: "po", instructions: "keep the plan", followUp: nil)])
        #expect(rig.source.messages.isEmpty)   // never typed into the pane
        // The box keeps the draft until the dashboard has the job (QA #2).
        #expect(rig.model.query == "/compact keep the plan" && rig.model.taggedAgentID == "a")
        let agent = try #require(row(rig))
        #expect(rig.model.sendingLabel(for: agent) == "Starting compact…")
        rig.source.script(idReads: [.job(J.job(.done, rowId: "a"))])
        rig.source.replyStart(.started(J.job(.waitingIdle, rowId: "a")))
        await waitUntil { rig.model.sendingLabel(for: agent) == "Waiting for agent…" }
        #expect(rig.model.query == "" && rig.model.taggedAgentID == nil)
        await poll(rig)
        #expect(rig.model.sendingLabel(for: agent) == nil)
        #expect(rig.model.sentLabel(for: agent) == "Compacted ✓")
        #expect(rig.model.footerNotice == nil)
    }

    @Test func aPeekBoxCompactStartsTheJobWithItsQueuedMessage() async {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.togglePeek()
        #expect(!rig.model.sendFromPeek("/compact\nthen run the tests\nand push"))   // the box clears on the 202 only
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.source.starts == [.init(rowId: "a", actor: "po", instructions: nil, followUp: "then run the tests and push")])
        #expect(rig.source.messages.isEmpty)
        rig.source.replyStart(.failed("test over"))
        await settleTasks()
    }

    @Test func aPlainTaggedMessageIsStillTyped() async {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.tagSelected()
        rig.model.query = "please continue"
        rig.model.activateSelected()
        await waitUntil { !rig.source.messages.isEmpty }
        #expect(rig.source.messages == ["please continue"])
        #expect(rig.source.starts.isEmpty)
    }

    @Test func aCompactWhoseQueuedMessageWasNotSentRepeatsItInTheFooter() async throws {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        #expect(rig.model.togglePeek())
        #expect(!rig.model.sendFromPeek("/compact\nrun the tests"))
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.job(J.job(.failed, rowId: "a", modelRestored: false, followUpSent: false, error: "dashboard restarted"))])
        rig.source.replyStart(.started(J.job(.compacting, rowId: "a")))
        await poll(rig)
        let notice = try #require(rig.model.footerNotice?.text)
        #expect(notice.contains("Compact failed: dashboard restarted"))
        #expect(notice.contains("Model NOT restored: still on Sonnet"))
        #expect(notice.contains("Your queued message was NOT sent: \u{201C}run the tests\u{201D}"))
    }

    @Test func aSecondMessageWhileCompactingIsRefused() async {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.togglePeek()
        #expect(!rig.model.sendFromPeek("/compact"))
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(!rig.model.sendFromPeek("are you done?"))
        #expect(rig.model.footerNotice?.text == AgentPanelModel.compactRunningNotice("worker-1"))
        #expect(!rig.model.sendFromPeek("/compact again"))
        #expect(rig.source.starts.count == 1 && rig.source.messages.isEmpty)
        rig.source.replyStart(.failed("test over"))
        await settleTasks()
    }

    // MARK: - The box keeps the draft until the dashboard has the job (QA #2)

    @Test func aRefusedTaggedCompactKeepsTheDraftExactlyAsTyped() async {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.tagSelected()
        let typed = "/compact keep the plan\n  then run the tests\n\nand push"
        rig.model.query = typed
        rig.model.activateSelected()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.replyStart(.failed("row a is not a Claude pane"))
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.footerNotice?.text == "Couldn't compact worker-1: row a is not a Claude pane")
        #expect(rig.model.query == typed)   // newlines and all
        #expect(rig.model.taggedAgentID == "a")
    }

    @Test func anAdoptedJobClearsTheTaggedDraft() async {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.tagSelected()
        rig.model.query = "/compact"
        rig.model.activateSelected()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.replyStart(.alreadyRunning(J.job(.compacting, rowId: "a")))
        await waitUntil { rig.model.query.isEmpty }
        #expect(rig.model.taggedAgentID == nil)
        rig.model.message.reset()
    }

    @Test func textTypedSinceThePressIsNotClearedByTheAcceptance() async {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.tagSelected()
        rig.model.query = "/compact"
        rig.model.activateSelected()
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.model.query = "something new"
        rig.source.replyStart(.started(J.job(.waitingIdle, rowId: "a")))
        await waitUntil { rig.source.idReads.isEmpty && rig.ticker.waiting == 1 }
        #expect(rig.model.query == "something new" && rig.model.taggedAgentID == "a")
        rig.model.message.reset()
    }

    @Test func thePeekBoxClearsOnlyOnceTheJobIsAccepted() async {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.togglePeek()
        let typed = "/compact\nthen run the tests"
        #expect(!rig.model.sendFromPeek(typed))
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.model.peekDraftEdit == nil)
        rig.source.replyStart(.started(J.job(.waitingIdle, rowId: "a")))
        await waitUntil { rig.model.peekDraftEdit != nil }
        #expect(rig.model.peekDraftEdit?.agentID == "a")
        #expect(rig.model.peekDraftEdit?.from == typed && rig.model.peekDraftEdit?.to == "")
        rig.model.message.reset()
    }

    @Test func aRefusedPeekCompactLeavesTheBoxAlone() async {
        let rig = makeRig([working()])
        rig.model.select(agentID: "a")
        rig.model.togglePeek()
        #expect(!rig.model.sendFromPeek("/compact x"))
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.replyStart(.failed("bad text"))
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.peekDraftEdit == nil)
    }

    // MARK: - Answers stay open while the job waits for idle (QA #2)

    @Test func aBlockedRowKeepsItsAnswerButtonUntilThePickerMayBeOpen() async throws {
        let rig = makeRig([working()])
        #expect(rig.model.press(.compact, on: "a") == nil)
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(
            idReads: [.job(J.job(.switchingModel, rowId: "a")), .job(J.job(.switchingModel, rowId: "a", inPicker: true))],
            then: .job(J.job(.switchingModel, rowId: "a", inPicker: true))
        )
        rig.source.replyStart(.started(J.job(.waitingIdle, rowId: "a")))
        await waitUntil { rig.ticker.waiting == 1 }
        // The agent asks something while the job waits for it to go idle.
        let asking = AnswerFixtures.blockedAgent("a", blocker: .question(AnswerFixtures.question()))
        rig.model.receive(F.snapshot([asking]))
        let blocked = try #require(rig.model.presentation.agents.first { $0.id == "a" })
        #expect(blocked.blockedOnYou != nil)
        #expect(rig.model.sendingLabel(for: blocked) == nil)
        rig.model.press(.answer, on: "a")
        #expect(rig.model.answer.isOpen)
        rig.model.answer.close()
        // A job state alone doesn't close answers: only the job's `inPicker` does (so does the dashboard).
        await poll(rig)
        #expect(rig.model.sendingLabel(for: blocked) == nil)
        await poll(rig)
        #expect(rig.model.sendingLabel(for: blocked) == "Switching to Sonnet…")
        rig.model.press(.answer, on: "a")
        #expect(!rig.model.answer.isOpen)
        rig.model.message.reset()
    }

    // MARK: - A plain send hitting a running compact (409 compact-running)

    @Test func aCompactRunningReplyIsFinalAndPutsTheTextBack() async throws {
        let rig = makeRig([working()])
        rig.source.messageOutcome = .compactRunning
        rig.model.select(agentID: "a")
        rig.model.tagSelected()
        rig.model.query = "please continue"
        rig.model.activateSelected()
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.footerNotice?.text == MessageSendOutcome.compactRunningWords)
        try await Task.sleep(for: .milliseconds(150))   // well past every retry delay (0.01s)
        #expect(rig.source.messages == ["please continue"])   // never retried
        #expect(rig.model.query == "please continue")
        let agent = try #require(row(rig))
        #expect(rig.model.sendingLabel(for: agent) == nil)
    }

    @Test func aCompactRunningReplyToAPeekSendPutsTheTextBackInThePeekBox() async {
        let rig = makeRig([working()])
        rig.source.messageOutcome = .compactRunning
        rig.model.select(agentID: "a")
        rig.model.togglePeek()
        #expect(rig.model.sendFromPeek("are you done?"))
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.footerNotice?.text == MessageSendOutcome.compactRunningWords)
        #expect(rig.model.peekDraftEdit?.from == "" && rig.model.peekDraftEdit?.to == "are you done?")
        #expect(rig.model.query.isEmpty)
    }

    // MARK: - A poll that says "unknown job" looks the row up first (QA #2)

    @Test func anUnknownJobIsLookedUpByRowBeforeLosingTrack() async throws {
        let rig = makeRig([working()])
        #expect(rig.model.press(.compact, on: "a") == nil)
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.none, .job(J.job(.done, rowId: "a"))])
        rig.source.rowRead = .job(J.job(.compacting, rowId: "a"))
        rig.source.replyStart(.started(J.job(.waitingIdle, rowId: "a")))
        await poll(rig)   // "unknown job"
        await waitUntil { rig.source.rowReads == ["a"] }
        await settleTasks()
        let agent = try #require(row(rig))
        #expect(rig.model.sendingLabel(for: agent) == "Compacting…")
        #expect(rig.model.footerNotice == nil)
        await poll(rig)
        #expect(rig.model.sentLabel(for: agent) == "Compacted ✓")
    }

    @Test func anUnknownJobTheRowLookUpCannotFindLosesTrack() async {
        let rig = makeRig([working()])
        #expect(rig.model.press(.compact, on: "a") == nil)
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.none])
        rig.source.rowRead = .none
        rig.source.replyStart(.started(J.job(.waitingIdle, rowId: "a")))
        await poll(rig)
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.source.rowReads == ["a"])
        #expect(rig.model.footerNotice?.text.hasPrefix("Lost track of worker-1's compact") == true)
    }

    // MARK: - The row's ⋯ Compact

    @Test func theMenusCompactStartsTheJobWithNoInstructions() async throws {
        let rig = makeRig([working()])
        #expect(rig.model.press(.compact, on: "a") == nil)
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.source.starts == [.init(rowId: "a", actor: "po", instructions: nil, followUp: nil)])
        #expect(rig.source.messages.isEmpty)
        let agent = try #require(row(rig))
        #expect(rig.model.press(.compact, on: "a") == nil)   // the row is busy: no second job
        #expect(rig.source.starts.count == 1)
        rig.source.replyStart(.failed("row a is not a Claude pane"))
        await waitUntil { rig.model.footerNotice != nil }
        #expect(rig.model.footerNotice?.text == "Couldn't compact worker-1: row a is not a Claude pane")
        #expect(rig.model.sendingLabel(for: agent) == nil)
    }

    /// The job reaches a remote pane over ssh, so the ⋯ menu offers Compact there (Clear, still typed,
    /// keeps needing hook data).
    @Test func aRemoteClaudePaneIsOfferedCompactButNotClear() async {
        let agent = remote()
        #expect(RowButtons.takesCompactJob(agent))
        #expect(!RowButtons.takesQuickCommands(agent))
        #expect(RowButtons.menuItems(for: agent).map(\.button) == [.compact])
        let rig = makeRig([agent])
        #expect(rig.model.press(.compact, on: "r") == nil)
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.source.starts.map(\.rowId) == ["r"])
        rig.source.replyStart(.failed("test over"))
        await settleTasks()
    }

    // MARK: - Park waits for the job

    @Test func parkStartsTheJobAndWaitsForItToFinish() async throws {
        let rig = makeRig([F.agent("a", label: "worker-1", section: .needsYou)])
        rig.model.press(.park, on: "a")
        let parked = try #require(rig.model.presentation.agents.first)
        #expect(parked.section == .parked)
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.source.starts == [.init(rowId: "a", actor: "po", instructions: nil, followUp: nil)])
        #expect(rig.source.messages.isEmpty)   // no typed /compact any more
        rig.source.script(idReads: [.job(J.job(.compacting, rowId: "a")), .job(J.job(.done, rowId: "a"))])
        rig.source.replyStart(.started(J.job(.switchingModel, rowId: "a")))
        await waitUntil { rig.model.sendingLabel(for: parked) == "Switching to Sonnet…" }
        await poll(rig)
        #expect(rig.model.sendingLabel(for: parked) == "Compacting…")   // still waiting on the job
        #expect(rig.model.press(.unpark, on: "a") == nil)
        #expect(rig.model.presentation.agents.first?.section == .parked)   // held while the job runs
        await poll(rig)
        #expect(rig.model.sendingLabel(for: parked) == nil)
        #expect(rig.model.sentLabel(for: parked) == "Compacted ✓")
        #expect(rig.model.footerNotice == nil)
        #expect(rig.model.presentation.agents.first?.section == .parked)
    }

    @Test func aFailedParkCompactKeepsTheRowParkedAndSaysWhy() async throws {
        let rig = makeRig([F.agent("a", label: "worker-1", section: .needsYou)])
        rig.model.press(.park, on: "a")
        await waitUntil { rig.source.pendingStartCount == 1 }
        rig.source.script(idReads: [.job(J.job(.failed, rowId: "a", modelRestored: true, error: "compact did not finish"))])
        rig.source.replyStart(.started(J.job(.compacting, rowId: "a")))
        await poll(rig)
        let parked = try #require(rig.model.presentation.agents.first)
        #expect(parked.section == .parked)
        #expect(rig.model.sendingLabel(for: parked) == nil)
        #expect(rig.model.sentLabel(for: parked) == nil)
        #expect(rig.model.footerNotice?.text == "worker-1: Compact failed: compact did not finish")
        await settleTasks()
        #expect(rig.source.starts.count == 1)   // never retried
    }

    @Test func parkingARemoteClaudePaneCompactsItToo() async {
        let rig = makeRig([remote(section: .needsYou)])
        rig.model.press(.park, on: "r")
        await waitUntil { rig.source.pendingStartCount == 1 }
        #expect(rig.source.starts.map(\.rowId) == ["r"])
        rig.source.replyStart(.failed("test over"))
        await settleTasks()
    }

    // MARK: - Rows the job can't serve keep today's behaviour

    @Test func anInboxRowIsNeverGivenACompactJob() async {
        let rig = makeRig([InboxFixtures.inboxAgent()])
        #expect(!RowButtons.takesCompactJob(InboxFixtures.inboxAgent()))
        rig.model.press(.park, on: StatusOnlyFixtures.desktopSession)
        await settleTasks()
        #expect(rig.source.starts.isEmpty)
    }
}
