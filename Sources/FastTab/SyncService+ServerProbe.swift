import Foundation
import CloudKit
import FastTabSync

// Live sync probe responder (see `SyncServerProbe` and `scripts/sync-probe.sh`):
// answers "which of this Mac's tab records does the server hold right now?"
// from the probe's own change feed of the state zone (own token, own mirror —
// never CKSyncEngine's token or the publish ledger). Strictly read-only: no
// record saves/deletes, no ledger, `serverRecordsByID` or health changes.

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
        if let recent = SyncServerProbe.reusableCatchUp(lastServerProbeCatchUp, now: startedAt) {
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
            serverRecords: outcome == .ok ? serverProbeMirror.records : [],
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

    private func catchUpServerProbeMirrorReportingOutcome() async -> SyncServerProbe.CatchUpResult {
        let outcome: SyncServerProbe.Outcome
        var errorMessage: String?
        do {
            try await catchUpServerProbeMirror()
            outcome = .ok
        } catch where SyncHealthDiagnostics.isExpectedMissingZone(error) {
            outcome = .zoneMissing
        } catch {
            outcome = .error
            errorMessage = error.localizedDescription
        }
        return SyncServerProbe.CatchUpResult(outcome: outcome, errorMessage: errorMessage, finishedAt: Date())
    }

    /// Only the fields the probe reports; keeps each change-feed page small.
    private nonisolated static let serverProbeDesiredKeys: [CKRecord.FieldKey] = ["browserName", "url"]

    /// Pages the probe's change feed up to now. Each page is applied and its
    /// token kept, so a failure mid-walk resumes where it stopped. An expired
    /// token restarts from a full walk.
    private func catchUpServerProbeMirror() async throws {
        var pageCount = 0
        while true {
            let zoneChanges: (
                modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, Error>],
                deletions: [CKDatabase.RecordZoneChange.Deletion],
                changeToken: CKServerChangeToken,
                moreComing: Bool
            )
            do {
                zoneChanges = try await database.recordZoneChanges(
                    inZoneWith: SyncConstants.stateZoneID,
                    since: serverProbeChangeToken,
                    desiredKeys: Self.serverProbeDesiredKeys
                )
            } catch let error as CKError where error.code == .changeTokenExpired {
                logger.info("Sync probe change token expired; restarting full walk")
                serverProbeMirror = SyncServerProbe.ZoneMirror()
                serverProbeChangeToken = nil
                continue
            }
            pageCount += 1
            var modifiedRecords: [CKRecord] = []
            var failedRecordCount = 0
            for modificationResult in zoneChanges.modificationResultsByID.values {
                switch modificationResult {
                case .success(let modification): modifiedRecords.append(modification.record)
                case .failure: failedRecordCount += 1
                }
            }
            guard failedRecordCount == 0 else {
                throw SyncServerProbe.IncompleteChangeFeedPage(failedRecordCount: failedRecordCount)
            }
            serverProbeMirror.apply(
                modified: modifiedRecords.map(Self.probeSummary(of:)),
                deletedRecordNames: zoneChanges.deletions.map(\.recordID.recordName)
            )
            serverProbeChangeToken = zoneChanges.changeToken
            guard zoneChanges.moreComing else { break }
        }
        if pageCount > 1 {
            logger.info("Sync probe walked \(pageCount) change-feed pages")
        }
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
