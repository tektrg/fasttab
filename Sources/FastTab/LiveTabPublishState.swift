import Foundation
import CloudKit
import FastTabSync

/// What this Mac has told CloudKit about its open tabs, and the decisions
/// that keep the server's `SyncedTab` records equal to the tabs actually open:
/// the publish save/delete diff (with its fingerprint skip), delete
/// acknowledgement, and the state-zone reconciliation sweep.
///
/// A value type with no CloudKit I/O: `SyncService` owns one, persists its
/// ledger, and turns each plan into `CKSyncEngine` changes. The scenario tests
/// (`LiveTabSyncScenarioTests`) drive the same type against an in-memory
/// server.
struct LiveTabPublishState {
    let deviceID: String
    /// Durable ledger: every tab record this device may still have on the
    /// server. Grows on publish, shrinks only when a delete is confirmed (or
    /// the reconciliation proves a record gone). The owner persists it.
    private(set) var publishedTabRecordIDs: Set<CKRecord.ID>
    /// Skip-gate: fingerprint of the last published snapshot. In memory only,
    /// so the first publish after launch always runs.
    private var lastPublishedContentFingerprint = ""

    struct PublishPlan {
        /// Every public tab in the snapshot; `SyncedTab.id` is its record name.
        let tabsToSave: [SyncedTab]
        let recordIDsToDelete: Set<CKRecord.ID>
    }

    /// A `SyncedTab` record as read back from the state zone.
    struct ServerTabRecord {
        let recordID: CKRecord.ID
        let browserName: String
    }

    struct ReconcilePlan {
        let orphanRecordIDs: Set<CKRecord.ID>
        /// This device's tab records found on the server.
        let serverRecordCount: Int
        let expectedRecordCount: Int
    }

    init(deviceID: String, publishedTabRecordIDs: Set<CKRecord.ID>) {
        self.deviceID = deviceID
        self.publishedTabRecordIDs = publishedTabRecordIDs
    }

    // MARK: - Publish

    /// The save/delete diff for a live-tab snapshot, or nil when its content
    /// is unchanged since the last publish (no CloudKit traffic at all).
    ///
    /// The unreadable set is part of the fingerprint: once a browser that
    /// failed becomes readable the publish must run (its delete diff prunes
    /// tabs that really closed), while a browser that stays unreadable (e.g.
    /// Automation permission denied) does not re-save every record.
    mutating func planPublish(_ tabs: [BrowserSearchResult], unreadableBrowsers: Set<String>) -> PublishPlan? {
        let publicTabs = tabs.filter { !SyncService.isIncognitoTab($0) }
        let contentFingerprint = SyncService.tabContentFingerprint(publicTabs)
            + SyncService.unreadableBrowsersFingerprintSuffix(unreadableBrowsers)
        guard contentFingerprint != lastPublishedContentFingerprint else { return nil }

        let tabsToSave = publicTabs.enumerated().map { index, tab in
            SyncedTab(
                id: SyncService.tabRecordName(
                    deviceID: deviceID,
                    browserName: tab.browserName,
                    windowIndex: tab.windowIndex,
                    tabIndex: tab.tabIndex,
                    tabID: tab.tabID,
                    fallbackIndex: index
                ),
                deviceID: deviceID,
                browserName: tab.browserName,
                title: tab.title,
                url: tab.url,
                timestamp: tab.timestamp,
                windowIndex: tab.windowIndex,
                tabIndex: tab.tabIndex,
                windowName: tab.windowName,
                tabID: tab.tabID,
                isAudible: tab.isAudible,
                isMuted: tab.isMuted,
                isPinned: tab.isPinned,
                isDiscarded: tab.isDiscarded,
                tabGroupTitle: tab.tabGroupTitle,
                profileName: tab.profileName
            )
        }
        let currentRecordIDs = Set(tabsToSave.map {
            CKRecord.ID(recordName: $0.id, zoneID: SyncConstants.stateZoneID)
        })
        let recordIDsToDelete = SyncService.tabRecordIDsToDelete(
            previouslyPublished: publishedTabRecordIDs,
            currentlyPublished: currentRecordIDs,
            sparingBrowsers: unreadableBrowsers,
            deviceID: deviceID
        )
        publishedTabRecordIDs = SyncService.tabRecordLedgerAfterPublishing(
            remotelyKnown: publishedTabRecordIDs,
            currentlyPublished: currentRecordIDs
        )
        lastPublishedContentFingerprint = contentFingerprint
        return PublishPlan(tabsToSave: tabsToSave, recordIDsToDelete: recordIDsToDelete)
    }

    /// CloudKit confirmed these deletes (our own sends).
    mutating func acknowledgeDeletions(_ deletedRecordIDs: Set<CKRecord.ID>) {
        publishedTabRecordIDs = SyncService.tabRecordLedgerAfterAcknowledgingDeletions(
            remotelyKnown: publishedTabRecordIDs,
            deletedRecordIDs: deletedRecordIDs
        )
    }

    /// Records the server reports gone (fetched deletions, e.g. deleted
    /// elsewhere). Also forgets the fingerprint, so a still-open tab whose
    /// record vanished is re-uploaded by the next publish instead of staying
    /// invisible until its tab set happens to change.
    mutating func forgetServerDeletedRecords(_ deletedRecordIDs: Set<CKRecord.ID>) {
        guard !publishedTabRecordIDs.isDisjoint(with: deletedRecordIDs) else { return }
        acknowledgeDeletions(deletedRecordIDs)
        lastPublishedContentFingerprint = ""
    }

    /// Account change: nothing published is known any more.
    mutating func reset() {
        publishedTabRecordIDs.removeAll()
        lastPublishedContentFingerprint = ""
    }

    // MARK: - Reconciliation

    /// The state-zone sweep: which of this device's server tab records are
    /// orphans (not in the fresh authoritative snapshot) and safe to delete.
    /// Also brings the ledger in line with what now exists on the server.
    ///
    /// Safety: never deletes a browser absent from the snapshot or unreadable
    /// in it (partial view, not closed tabs), nor a record a publish is still
    /// saving (`isPendingSave`). Ghost pinned slots count as expected.
    mutating func planReconcile(
        serverTabRecords: [ServerTabRecord],
        snapshot: AuthoritativeLiveTabSnapshot,
        ghostTabs: [BrowserSearchResult],
        isPendingSave: (CKRecord.ID) -> Bool
    ) -> ReconcilePlan {
        // Mirror the publish path exactly: incognito/private tabs are filtered
        // out before record names are derived.
        let expectedTabs = snapshot.tabs.filter { !SyncService.isIncognitoTab($0) } + ghostTabs
        let expectedRecordIDs = SyncService.tabRecordIDs(from: expectedTabs, deviceID: deviceID)
        let snapshotBrowsers = Set(expectedTabs.map(\.browserName))
        let myTabRecords = serverTabRecords.filter { $0.recordID.recordName.hasPrefix("\(deviceID)_") }

        let orphanRecordIDs = Set(myTabRecords.filter { record in
            !expectedRecordIDs.contains(record.recordID)
                && !isPendingSave(record.recordID)
                && SyncService.reconcileMayDeleteRecords(
                    ofBrowser: record.browserName,
                    snapshotBrowsers: snapshotBrowsers,
                    unreadableBrowsers: snapshot.unreadableBrowsers
                )
        }.map(\.recordID))

        // The current live set, minus what is being deleted, plus any
        // ledger-known records the sweep could not safely touch, so the
        // normal publish path keeps retrying them.
        publishedTabRecordIDs.formUnion(expectedRecordIDs)
        publishedTabRecordIDs.subtract(orphanRecordIDs)
        return ReconcilePlan(
            orphanRecordIDs: orphanRecordIDs,
            serverRecordCount: myTabRecords.count,
            expectedRecordCount: expectedRecordIDs.count
        )
    }
}
