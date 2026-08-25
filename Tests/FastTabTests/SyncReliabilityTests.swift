import Testing
import Foundation
@testable import FastTab
import FastTabSync

private enum SyncDelegateCallbackContext {
    @TaskLocal static var isActive = false
}

private actor SyncSendProbe {
    struct Snapshot {
        let delegateContextValues: [Bool]
        let maximumConcurrentSends: Int
    }

    private var delegateContextValues: [Bool] = []
    private var activeSendCount = 0
    private var maximumConcurrentSends = 0
    private var firstSendStarted = false
    private var firstSendContinuation: CheckedContinuation<Void, Never>?

    func send() async {
        activeSendCount += 1
        maximumConcurrentSends = max(maximumConcurrentSends, activeSendCount)
        delegateContextValues.append(SyncDelegateCallbackContext.isActive)

        if !firstSendStarted {
            firstSendStarted = true
            await withCheckedContinuation { continuation in
                firstSendContinuation = continuation
            }
        }

        activeSendCount -= 1
    }

    func waitForFirstSendToStart() async {
        while !firstSendStarted {
            await Task.yield()
        }
    }

    func releaseFirstSend() {
        firstSendContinuation?.resume()
        firstSendContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            delegateContextValues: delegateContextValues,
            maximumConcurrentSends: maximumConcurrentSends
        )
    }
}

@Suite("Sync Reliability")
struct SyncReliabilityTests {
    @Test("Sync sends detach from delegate callbacks and coalesce overlapping requests")
    func syncSendsDetachAndSerialize() async {
        let probe = SyncSendProbe()
        let coordinator = SyncSendCoordinator {
            await probe.send()
        }

        await SyncDelegateCallbackContext.$isActive.withValue(true) {
            await coordinator.requestSend()
        }
        await probe.waitForFirstSendToStart()

        for _ in 0..<20 {
            await coordinator.requestSend()
        }

        await probe.releaseFirstSend()
        await coordinator.waitUntilIdle()

        let snapshot = await probe.snapshot()
        #expect(snapshot.delegateContextValues == [false, false])
        #expect(snapshot.maximumConcurrentSends == 1)
    }

    @Test("Source-scoped fetch cannot replace authoritative all-browser tabs")
    func scopedFetchPreservesOtherBrowsers() {
        let chrome = BrowserSearchResult(
            title: "Chrome",
            url: "https://chrome.example",
            browserName: "Google Chrome",
            type: .tab,
            timestamp: Date(),
            tabID: 1
        )
        let safari = BrowserSearchResult(
            title: "Safari",
            url: "https://safari.example",
            browserName: "Safari",
            type: .tab,
            timestamp: Date(),
            tabID: 2
        )
        var snapshot = AuthoritativeLiveTabSnapshot()

        snapshot.applyAllBackends([chrome, safari])
        snapshot.observeScopedFetch([chrome])

        #expect(snapshot.isHydrated)
        #expect(Set(snapshot.tabs.map(\.browserName)) == ["Google Chrome", "Safari"])
    }

    @Test("Completed command response survives journal reinitialization")
    func commandResultOutboxRestoresAfterCrash() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("command-journal.json")
        let pending = SyncCommand(
            id: "close_once",
            kind: .closeTab,
            targetDeviceID: "mac",
            sourceDeviceName: "iPhone",
            payloadJSON: "{}"
        )
        var completed = pending
        completed.status = .done
        completed.statusReason = "Tab closed on Mac"
        completed.completedAt = Date()

        let firstProcess = SyncCommandJournal(fileURL: fileURL)
        try firstProcess.markExecuting(pending)
        try firstProcess.storeCompletedResponse(completed)

        let relaunchedProcess = SyncCommandJournal(fileURL: fileURL)

        #expect(relaunchedProcess.completedResponses == [completed])
    }

    @Test("Executing command is recoverable after journal reinitialization")
    func executingCommandRecoversAfterCrash() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let pending = SyncCommand(
            id: "close_interrupted",
            kind: .closeTab,
            targetDeviceID: "mac",
            sourceDeviceName: "iPhone",
            payloadJSON: "{}"
        )

        try SyncCommandJournal(fileURL: fileURL).markExecuting(pending)
        let relaunchedProcess = SyncCommandJournal(fileURL: fileURL)

        #expect(relaunchedProcess.executingCommands == [pending])
    }

    @Test("Duplicate pending close uses durable executing or completed state")
    func duplicatePendingCommandDecision() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let pending = SyncCommand(
            id: "duplicate_close",
            kind: .closeTab,
            targetDeviceID: "mac",
            sourceDeviceName: "iPhone",
            payloadJSON: "{}"
        )
        let journal = SyncCommandJournal(fileURL: fileURL)

        #expect(journal.decision(for: pending) == .execute)

        try journal.markExecuting(pending)
        #expect(journal.decision(for: pending) == .reconcileExecuting(pending))

        var completed = pending
        completed.status = .done
        completed.completedAt = Date()
        try journal.storeCompletedResponse(completed)
        #expect(journal.decision(for: pending) == .resendCompleted(completed))
    }

    // MARK: - At-least-once redelivery from the phone's durable outbox

    /// Builds a command the way a re-upload from the phone's outbox arrives:
    /// re-derived from stored values, so back at `.pending` with the same id.
    private func phoneCommand(
        id: String,
        kind: SyncCommandKind = .closeTab,
        expiresIn: TimeInterval = SyncCommand.defaultTTL
    ) -> SyncCommand {
        SyncCommand(
            id: id,
            kind: kind,
            targetDeviceID: "mac",
            sourceDeviceName: "iPhone",
            expiresAt: Date().addingTimeInterval(expiresIn),
            payloadJSON: "{}"
        )
    }

    @Test("A re-uploaded command already answered and acked is resent, never re-executed")
    func acknowledgedCommandSurvivesPhoneReupload() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pending = phoneCommand(id: "close_acked")
        var done = pending
        done.status = .done
        done.statusReason = "Tab closed on Mac"
        done.completedAt = Date()

        // Mac executes, answers, and CloudKit confirms the answering write.
        let firstProcess = SyncCommandJournal(fileURL: fileURL)
        try firstProcess.markExecuting(pending)
        try firstProcess.storeCompletedResponse(done)
        try firstProcess.acknowledgeCompletedResponse(commandID: pending.id)

        // The outbox is empty — that response is delivered and must not be
        // re-queued on every relaunch.
        #expect(firstProcess.completedResponses.isEmpty)
        #expect(firstProcess.executingCommands.isEmpty)

        // The phone never saw its own save confirmation, so it re-uploads the
        // command at `.pending`. Same process and after relaunch, the answer is
        // resent rather than the tab being closed a second time.
        #expect(firstProcess.decision(for: pending) == .resendCompleted(done))

        let relaunchedProcess = SyncCommandJournal(fileURL: fileURL)
        #expect(relaunchedProcess.decision(for: pending) == .resendCompleted(done))
        #expect(relaunchedProcess.settledResponses == [done])
    }

    @Test("Resending a settled answer re-arms the outbox so the phone can learn the outcome")
    func resentAnswerReentersTheOutbox() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pending = phoneCommand(id: "close_resend")
        var done = pending
        done.status = .done
        done.completedAt = Date()

        let journal = SyncCommandJournal(fileURL: fileURL)
        try journal.storeCompletedResponse(done)
        try journal.acknowledgeCompletedResponse(commandID: pending.id)

        // This is what `handleIncomingCommand` does with `.resendCompleted`:
        // push the terminal response again, which is what corrects the
        // `.pending` the phone's re-upload wrote over the top of it.
        guard case .resendCompleted(let response) = journal.decision(for: pending) else {
            Issue.record("Expected the acked answer to be resent")
            return
        }
        try journal.storeCompletedResponse(response)

        #expect(journal.completedResponses == [done])
        // The settled copy is superseded by the in-flight one, so only one
        // answer exists at a time and the stale one cannot be resent later.
        #expect(journal.settledResponses.isEmpty)
        #expect(journal.decision(for: pending) == .resendCompleted(done))
    }

    @Test("A newer answer supersedes an already-settled one for the same command")
    func newerAnswerSupersedesSettledAnswer() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pending = phoneCommand(id: "delete_bookmark", kind: .deleteBookmark)
        var queued = pending
        queued.status = .needsApproval

        let journal = SyncCommandJournal(fileURL: fileURL)
        try journal.storeCompletedResponse(queued)
        try journal.acknowledgeCompletedResponse(commandID: pending.id)
        #expect(journal.decision(for: pending) == .resendCompleted(queued))

        // The user approves later: the `.done` answer must be the one resent
        // from then on, not the stale `.needsApproval`.
        var approved = pending
        approved.status = .done
        approved.completedAt = Date()
        try journal.storeCompletedResponse(approved)
        try journal.acknowledgeCompletedResponse(commandID: pending.id)

        #expect(journal.settledResponses == [approved])
        #expect(journal.decision(for: pending) == .resendCompleted(approved))
    }

    // MARK: - Bounding the anti-replay ledger

    @Test("The settled ledger forgets only commands that can no longer be delivered")
    func settledLedgerEvictsExpiredEntriesOnly() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let stillActionable = phoneCommand(id: "still_actionable", expiresIn: 3600)
        let pastTTL = phoneCommand(id: "past_ttl", expiresIn: -1)

        let journal = SyncCommandJournal(fileURL: fileURL)
        for command in [stillActionable, pastTTL] {
            var response = command
            response.status = .done
            response.completedAt = Date()
            try journal.storeCompletedResponse(response)
            try journal.acknowledgeCompletedResponse(commandID: command.id)
        }

        #expect(journal.settledResponses.map(\.id) == ["still_actionable"])

        // Eviction is safe precisely because the dropped entry can never reach
        // the duplicate check again: `handleIncomingCommand` answers it
        // `.expired` first. The kept entry is still reachable, so it is kept.
        #expect(SyncService.hasExpired(pastTTL))
        #expect(!SyncService.hasExpired(stillActionable))

        // And the eviction survives a relaunch rather than being reloaded.
        let relaunchedProcess = SyncCommandJournal(fileURL: fileURL)
        #expect(relaunchedProcess.settledResponses.map(\.id) == ["still_actionable"])
    }

    @Test("A ledger that aged while the app was closed is trimmed on load")
    func settledLedgerEvictsOnLoad() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // A journal written days ago: one entry still inside its TTL, one that
        // aged out while the Mac was shut down. Nothing writes on launch, so
        // eviction has to happen at load or the ledger only ever grows.
        var longLived = phoneCommand(id: "long_lived", expiresIn: 6 * 24 * 3600)
        longLived.status = .done
        var agedOut = phoneCommand(id: "aged_out", expiresIn: -3600)
        agedOut.status = .done
        let persisted: [String: [String: SyncCommand]] = [
            "settled": [longLived.id: longLived, agedOut.id: agedOut]
        ]
        try JSONEncoder().encode(persisted).write(to: fileURL, options: .atomic)

        let journal = SyncCommandJournal(fileURL: fileURL)
        #expect(journal.settledResponses.map(\.id) == ["long_lived"])
    }

    @Test("A count cap backstops a peer that stamps absurd expiry dates")
    func settledLedgerCountCapBoundsTheStore() {
        let cap = SyncCommandJournal.settledResponseCountCap
        let now = Date()
        var settled: [String: SyncCommand] = [:]
        for index in 0..<(cap + 88) {
            let command = SyncCommand(
                id: String(format: "cmd_%04d", index),
                kind: .closeTab,
                targetDeviceID: "mac",
                sourceDeviceName: "iPhone",
                // Every entry is unexpired, so only the cap can bound this.
                expiresAt: now.addingTimeInterval(3600 + Double(index)),
                payloadJSON: "{}"
            )
            settled[command.id] = command
        }

        let retained = SyncCommandJournal.retainedSettledResponses(settled, now: now)

        #expect(retained.count == cap)
        // The entries closest to expiring are the ones dropped: their
        // protection was about to lapse anyway.
        #expect(retained["cmd_0599"] != nil)
        #expect(retained["cmd_0000"] == nil)
        #expect(retained.values.allSatisfy { $0.expiresAt > now })
    }

    // MARK: - Degrading safely

    @Test("A corrupt journal degrades to remembering nothing instead of crashing")
    func corruptJournalDegradesSafely() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("{ not json at all".utf8).write(to: fileURL, options: .atomic)

        let journal = SyncCommandJournal(fileURL: fileURL)
        #expect(journal.settledResponses.isEmpty)
        #expect(journal.completedResponses.isEmpty)
        #expect(journal.executingCommands.isEmpty)

        // And it is still writable afterwards, so one bad file does not stop
        // this Mac answering commands for the rest of its life.
        let pending = phoneCommand(id: "after_corruption")
        #expect(journal.decision(for: pending) == .execute)
        var done = pending
        done.status = .done
        try journal.storeCompletedResponse(done)
        try journal.acknowledgeCompletedResponse(commandID: pending.id)
        #expect(journal.decision(for: pending) == .resendCompleted(done))
    }

    @Test("A missing journal file is an empty journal, not a failure")
    func missingJournalDegradesSafely() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("never-written-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let journal = SyncCommandJournal(fileURL: fileURL)
        #expect(journal.settledResponses.isEmpty)
        #expect(journal.decision(for: phoneCommand(id: "fresh")) == .execute)
    }

    @Test("A journal from a build without the settled ledger still loads its in-flight work")
    func legacyJournalWithoutSettledLedgerStillLoads() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Exactly the shape the previous build wrote: no `settled` key. Treating
        // it as corrupt would silently drop an answer for a tab already closed.
        let interrupted = phoneCommand(id: "legacy_executing")
        var undelivered = phoneCommand(id: "legacy_completed")
        undelivered.status = .done
        undelivered.completedAt = Date()
        let legacy: [String: [String: SyncCommand]] = [
            "executing": [interrupted.id: interrupted],
            "completed": [undelivered.id: undelivered]
        ]
        try JSONEncoder().encode(legacy).write(to: fileURL, options: .atomic)

        let journal = SyncCommandJournal(fileURL: fileURL)
        #expect(journal.executingCommands == [interrupted])
        #expect(journal.completedResponses == [undelivered])
        #expect(journal.settledResponses.isEmpty)
    }

    // MARK: - Interrupted close reconciliation must be untouched

    @Test("An interrupted close is still reconciled, and a settled one is not re-entered")
    func interruptedCloseReconciliationIsPreserved() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-journal.json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pending = phoneCommand(id: "close_interrupted_mid_flight")
        let journal = SyncCommandJournal(fileURL: fileURL)
        try journal.markExecuting(pending)

        // Crashed mid-close: re-entered through the reconciliation path, which
        // treats an already-absent tab as done rather than closing blind.
        #expect(SyncCommandJournal(fileURL: fileURL).decision(for: pending) == .reconcileExecuting(pending))
        // closeTab must stay the one kind that is re-entered rather than refused.
        #expect(SyncService.terminalResponseForInterruptedCommand(pending) == nil)

        // Once answered and acked, the same command must stop reconciling and
        // start resending — reconciling again would run the close a second time.
        var done = pending
        done.status = .done
        done.completedAt = Date()
        try journal.storeCompletedResponse(done)
        try journal.acknowledgeCompletedResponse(commandID: pending.id)

        #expect(journal.executingCommands.isEmpty)
        #expect(journal.decision(for: pending) == .resendCompleted(done))
    }
}
