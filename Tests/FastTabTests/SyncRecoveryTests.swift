import Testing
import Foundation
import CloudKit
@testable import FastTab
import FastTabSync

@Suite("Sync Recovery, Health & Command TTL")
struct SyncRecoveryTests {

    // MARK: - Command TTL

    @Test("A command outlives a Mac that is asleep, quit, or App-Napped for days")
    func commandTTLSurvivesALongSleep() {
        #expect(SyncCommand.defaultTTL == 7 * 24 * 60 * 60)

        let issuedAt = Date()
        let command = SyncCommand(
            kind: .closeTab,
            targetDeviceID: "mac_test",
            sourceDeviceName: "iPhone",
            payloadJSON: "{}"
        )

        // Six days asleep must still leave the intent actionable; the old 15
        // minute window silently discarded it.
        #expect(command.expiresAt > issuedAt.addingTimeInterval(6 * 24 * 3600))
        #expect(command.expiresAt <= Date().addingTimeInterval(SyncCommand.defaultTTL))
    }

    // MARK: - Token-independent reconciliation

    @Test("Reconciliation replays only this Mac's still-pending commands")
    func reconciliationFiltersByDeviceAndStatus() {
        let zoneID = SyncConstants.commandsZoneID

        func commandRecord(
            id: String,
            targetDeviceID: String,
            status: SyncCommandStatus,
            expiresAt: Date = Date().addingTimeInterval(3600)
        ) -> CKRecord {
            var command = SyncCommand(
                id: id,
                kind: .closeTab,
                targetDeviceID: targetDeviceID,
                sourceDeviceName: "iPhone",
                expiresAt: expiresAt,
                payloadJSON: "{}"
            )
            command.status = status
            return command.toRecord(zoneID: zoneID)
        }

        let records: [CKRecord] = [
            commandRecord(id: "mine_pending", targetDeviceID: "mac_test", status: .pending),
            commandRecord(id: "broadcast_empty", targetDeviceID: "", status: .pending),
            commandRecord(id: "broadcast_star", targetDeviceID: "*", status: .pending),
            commandRecord(id: "other_mac_pending", targetDeviceID: "mac_other", status: .pending),
            commandRecord(id: "mine_done", targetDeviceID: "mac_test", status: .done),
            commandRecord(id: "mine_needs_approval", targetDeviceID: "mac_test", status: .needsApproval),
            commandRecord(id: "mine_refused", targetDeviceID: "mac_test", status: .refused),
            // Expired but still pending: kept on purpose, because replaying it is
            // what writes the `.expired` status that retires the server record.
            commandRecord(
                id: "mine_pending_expired",
                targetDeviceID: "mac_test",
                status: .pending,
                expiresAt: Date().addingTimeInterval(-3600)
            ),
            // A foreign record type in the same zone must be ignored outright.
            CKRecord(
                recordType: "SomeOtherRecordType",
                recordID: CKRecord.ID(recordName: "not_a_command", zoneID: zoneID)
            )
        ]

        let replayable = IncomingCommandFilter.redeliverableCommands(in: records, deviceID: "mac_test")

        #expect(
            Set(replayable.map(\.id)) == [
                "mine_pending",
                "broadcast_empty",
                "broadcast_star",
                "mine_pending_expired"
            ]
        )
    }

    @Test("Addressing accepts this device and legacy broadcasts only")
    func commandAddressing() {
        func command(target: String) -> SyncCommand {
            SyncCommand(
                kind: .closeTab,
                targetDeviceID: target,
                sourceDeviceName: "iPhone",
                payloadJSON: "{}"
            )
        }

        #expect(IncomingCommandFilter.isAddressedToDevice(command(target: "mac_test"), deviceID: "mac_test"))
        #expect(IncomingCommandFilter.isAddressedToDevice(command(target: ""), deviceID: "mac_test"))
        #expect(IncomingCommandFilter.isAddressedToDevice(command(target: "*"), deviceID: "mac_test"))
        #expect(!IncomingCommandFilter.isAddressedToDevice(command(target: "mac_other"), deviceID: "mac_test"))
    }

    // MARK: - Health

    @Test("iCloud account status maps onto publishable health")
    func accountStatusMapping() {
        #expect(SyncHealthDiagnostics.health(forAccountStatus: .available) == .ok)
        #expect(SyncHealthDiagnostics.health(forAccountStatus: .noAccount) == .noAccount)
        #expect(SyncHealthDiagnostics.health(forAccountStatus: .restricted) == .restricted)
        // Neither of these is user-actionable, so neither may render as a failure.
        #expect(SyncHealthDiagnostics.health(forAccountStatus: .couldNotDetermine) == .unknown)
        #expect(SyncHealthDiagnostics.health(forAccountStatus: .temporarilyUnavailable) == .unknown)

        #expect(SyncHealth.noAccount.isBlocked)
        #expect(SyncHealth.restricted.isBlocked)
        #expect(!SyncHealth.unknown.isBlocked)
    }

    @Test("CloudKit failures become plain-English messages, never error dumps")
    func errorMessageMapping() {
        func message(_ code: CKError.Code) -> String {
            SyncHealthDiagnostics.userPresentableMessage(for: CKError(code))
        }

        #expect(message(.networkUnavailable).contains("No connection to iCloud"))
        #expect(message(.networkFailure).contains("No connection to iCloud"))
        #expect(message(.serviceUnavailable).contains("No connection to iCloud"))
        #expect(message(.quotaExceeded).contains("iCloud storage is full"))
        #expect(message(.notAuthenticated).contains("not signed in to iCloud"))
        #expect(message(.requestRateLimited).contains("slow down"))
        #expect(message(.zoneBusy).contains("slow down"))
        #expect(message(.permissionFailure).contains("restricted"))
        #expect(message(.changeTokenExpired).contains("resync"))

        // A partial failure's own description is useless; the actionable cause
        // lives in the per-item errors.
        let partialFailure = CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    CKRecord.ID(recordName: "rec_1"): CKError(.quotaExceeded)
                ]
            ]
        )
        #expect(SyncHealthDiagnostics.userPresentableMessage(for: partialFailure).contains("iCloud storage is full"))

        // Anything unrecognised falls back to the system description, and a
        // non-CloudKit error passes straight through.
        struct DiskFullError: LocalizedError {
            var errorDescription: String? { "The disk is full." }
        }
        #expect(SyncHealthDiagnostics.userPresentableMessage(for: DiskFullError()) == "The disk is full.")

        for code in [CKError.Code.networkUnavailable, .quotaExceeded, .notAuthenticated, .requestRateLimited] {
            #expect(!message(code).contains("CKError"))
        }
    }

    @Test("A missing commands zone is expected, a quota failure is not")
    func missingZoneIsNotAFailure() {
        #expect(SyncHealthDiagnostics.isExpectedMissingZone(CKError(.zoneNotFound)))
        #expect(SyncHealthDiagnostics.isExpectedMissingZone(CKError(.userDeletedZone)))
        #expect(SyncHealthDiagnostics.isExpectedMissingZone(CKError(.unknownItem)))
        #expect(!SyncHealthDiagnostics.isExpectedMissingZone(CKError(.quotaExceeded)))
        #expect(!SyncHealthDiagnostics.isExpectedMissingZone(CKError(.networkUnavailable)))
    }

    // MARK: - Stale pending changes

    @Test("Pending saves with no cached record are dropped deliberately, not silently")
    func stalePendingSavesAreSeparatedFromDeliverableWork() {
        let zoneID = SyncConstants.stateZoneID
        let backedRecordID = CKRecord.ID(recordName: "backed", zoneID: zoneID)
        let unbackedRecordID = CKRecord.ID(recordName: "unbacked", zoneID: zoneID)
        let deletedRecordID = CKRecord.ID(recordName: "deleted", zoneID: zoneID)

        let plan = SyncRecordBatchPlanner.plan(
            pendingChanges: [
                .saveRecord(backedRecordID),
                .saveRecord(unbackedRecordID),
                .deleteRecord(deletedRecordID)
            ],
            availableRecordIDs: [backedRecordID]
        )

        // A delete carries no content, so it is always deliverable.
        #expect(plan.deliverableChanges == [.saveRecord(backedRecordID), .deleteRecord(deletedRecordID)])
        #expect(plan.stalePendingSaves == [.saveRecord(unbackedRecordID)])
    }

    @Test("A fully backed batch reports nothing stale")
    func fullyBackedBatchHasNoStaleSaves() {
        let recordID = CKRecord.ID(recordName: "backed", zoneID: SyncConstants.stateZoneID)
        let plan = SyncRecordBatchPlanner.plan(
            pendingChanges: [.saveRecord(recordID)],
            availableRecordIDs: [recordID]
        )

        #expect(plan.stalePendingSaves.isEmpty)
        #expect(plan.deliverableChanges == [.saveRecord(recordID)])
    }
}
