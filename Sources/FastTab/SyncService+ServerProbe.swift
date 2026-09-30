import Foundation
import CloudKit
import FastTabSync

// Live sync probe responder (see `SyncServerProbe` and `scripts/sync-probe.sh`):
// answers "which of this Mac's tab records does the server hold right now?"
// from the shared `StateZoneMirror` (own change feed — never CKSyncEngine's
// token or the publish ledger). Strictly read-only: no record saves/deletes,
// no ledger, `serverRecordsByID` or health changes.

extension SyncService {
    /// `.deliverImmediately`: FastTab is a background (accessory) app, and
    /// distributed notifications are otherwise held while the app is inactive.
    func startServerProbeListener() {
        guard !isListeningForServerProbe else { return }
        isListeningForServerProbe = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleServerProbeNotification(_:)),
            name: SyncServerProbe.requestNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc nonisolated private func handleServerProbeNotification(_ notification: Notification) {
        guard let request = SyncServerProbe.parseRequest(userInfo: notification.userInfo) else { return }
        Task { @MainActor [weak self] in
            self?.enqueueServerProbe(request)
        }
    }

    /// One zone read at a time; a request arriving mid-read replaces any
    /// queued one (the script only waits for its newest request).
    private func enqueueServerProbe(_ request: SyncServerProbe.Request) {
        queuedServerProbeRequest = request
        guard !isAnsweringServerProbe else { return }
        isAnsweringServerProbe = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isAnsweringServerProbe = false }
            while let next = self.queuedServerProbeRequest {
                self.queuedServerProbeRequest = nil
                await self.answerServerProbe(next)
            }
        }
    }

    private func answerServerProbe(_ request: SyncServerProbe.Request) async {
        let startedAt = Date()
        let catchUp: SyncServerProbe.CatchUpResult
        // Reuse only while the mirror is whole and fully readable: a walk
        // since (e.g. a reconcile's rebaseline) may have changed that.
        if !stateZoneMirror.isRebuilding, stateZoneMirror.unreadableRecordNames.isEmpty,
           let recent = SyncServerProbe.reusableCatchUp(lastServerProbeCatchUp, now: startedAt) {
            catchUp = recent
        } else {
            catchUp = await catchUpServerProbeMirrorReportingOutcome()
            lastServerProbeCatchUp = catchUp
        }
        let outcome = catchUp.outcome
        let errorMessage = catchUp.errorMessage
        let response = SyncServerProbe.makeResponse(
            request: request,
            deviceID: deviceID,
            syncHealth: syncHealth,
            outcome: outcome,
            errorMessage: errorMessage,
            serverRecords: outcome == .ok ? stateZoneMirror.records.map(Self.probeSummary(of:)) : [],
            completedAt: Date()
        )
        do {
            try SyncServerProbe.writeResponse(
                response,
                to: SyncServerProbe.responseFileURL(fastTabSupportDirectory: fastTabSupportDirectory)
            )
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            logger.info("Sync probe answered in \(elapsedMs)ms: outcome=\(outcome.rawValue, privacy: .public) matches=\(response.matchingTabs.count) deviceTabRecords=\(response.thisDeviceTabRecordCount)")
        } catch {
            logger.error("Sync probe answer write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `ok` only when the shared mirror is complete: an unreadable entry
    /// could be the probe's own tab, so the answer would not be the truth.
    private func catchUpServerProbeMirrorReportingOutcome() async -> SyncServerProbe.CatchUpResult {
        let outcome: SyncServerProbe.Outcome
        var errorMessage: String?
        do {
            try await catchUpStateZoneMirror(reason: "sync probe")
            let unreadableCount = stateZoneMirror.unreadableRecordNames.count
            if unreadableCount == 0 {
                outcome = .ok
            } else {
                outcome = .error
                errorMessage = SyncServerProbe.UnreadableChangeFeedEntries(unreadableRecordCount: unreadableCount).localizedDescription
            }
        } catch where SyncHealthDiagnostics.isExpectedMissingZone(error) {
            outcome = .zoneMissing
        } catch {
            outcome = .error
            errorMessage = error.localizedDescription
        }
        return SyncServerProbe.CatchUpResult(outcome: outcome, errorMessage: errorMessage, finishedAt: Date())
    }

    private nonisolated static func probeSummary(of record: CKRecord) -> SyncServerProbe.ServerRecordSummary {
        SyncServerProbe.ServerRecordSummary(
            recordType: record.recordType,
            recordName: record.recordID.recordName,
            browserName: record["browserName"] as? String ?? "",
            url: record.encryptedValues["url"] as? String
        )
    }
}
