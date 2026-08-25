import Foundation
import CloudKit
import OSLog
import FastTabSync

// Split out of SyncService.swift: live-tab publish coalescing and the
// state-zone tab reconciliation both exist to keep the server's tab records
// converging to the tabs actually open in the browser.

extension SyncService {
    /// How often the state-zone reconciliation re-reads every tab record this
    /// device has ever published. Deliberately slow: the publish path is the
    /// primary sync mechanism, and this sweep is the safety net that catches
    /// records stranded by a naming-scheme change, a reset, or a raced publish
    /// — records the publish path's delete diff can never see.
    nonisolated private static let tabReconcileInterval: TimeInterval = 10 * 60

    /// Maximum age of the authoritative live-tab snapshot a reconciliation is
    /// willing to trust. Older snapshots may reflect a partial fetch, and
    /// deleting records against a partial view of the world would hide open
    /// tabs. Kept under the cache-refresh cadence so a reconcile never deletes
    /// against a snapshot that predates a tab the user just opened.
    nonisolated private static let maxSnapshotAgeForReconcile: TimeInterval = 60

    /// Startup retry budget: how many 5-second waits before giving the
    /// authoritative snapshot time to hydrate. The periodic timer is the
    /// eventual backstop.
    nonisolated private static let tabReconcileStartupRetries = 6

    // MARK: - Single live-tab publisher

    /// The one entry point for live-tab sync. Both the command bar's debounced
    /// refresh and the authoritative all-browser refresh can fire within
    /// milliseconds of each other; coalescing here means the newest snapshot
    /// wins and exactly one publish runs per MainActor turn, so two publishers
    /// can never interleave their record batches and undo each other's
    /// deletions.
    func requestLiveTabsPublish(_ tabs: [BrowserSearchResult]) {
        pendingLiveTabs = tabs
        guard liveTabsPublishTask == nil else { return }
        liveTabsPublishTask = Task { @MainActor [weak self] in
            defer { self?.liveTabsPublishTask = nil }
            let latest = self?.pendingLiveTabs
            self?.pendingLiveTabs = nil
            if let latest {
                self?.publishLiveTabsNow(latest)
            }
        }
    }

    // MARK: - State-zone reconciliation

    func startTabReconcileTimer() {
        tabReconcileTimer?.invalidate()
        tabReconcileTimer = Timer.scheduledTimer(
            withTimeInterval: Self.tabReconcileInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.reconcileStateZoneTabs()
            }
        }

        // First run shortly after launch, once the authoritative snapshot has
        // had a chance to hydrate. Retries a few times in case a browser fetch
        // is slow; the periodic timer above is the eventual backstop.
        Task { @MainActor [weak self] in
            for _ in 0..<Self.tabReconcileStartupRetries {
                guard let self else { return }
                if await self.reconcileStateZoneTabs() { return }
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            }
        }
    }

    /// Re-reads every `SyncedTab` record this device has ever published and
    /// deletes any not present in the current authoritative live-tab snapshot.
    ///
    /// The publish path only deletes what its durable ledger remembers; a
    /// record stranded by a naming-scheme change, a `resetPublishState`, or a
    /// raced publish is invisible to it and would otherwise live on the server
    /// (and show on the phone) forever. This sweep converges the server to the
    /// truth regardless of ledger state.
    ///
    /// Returns `true` when it ran against a fresh snapshot, `false` when
    /// deferred (not hydrated yet, or the snapshot is stale).
    @discardableResult
    func reconcileStateZoneTabs() async -> Bool {
        guard !isReconcilingTabs else { return true }
        isReconcilingTabs = true
        defer { isReconcilingTabs = false }
        guard let syncEngine else { return false }
        guard freshAuthoritativeSnapshot() != nil else {
            logger.info("Tab reconciliation deferred: authoritative live-tab snapshot not fresh")
            return false
        }

        // Token-independent full re-read: every record in the state zone, so a
        // record stranded outside the ledger is still found. Mirrors the
        // pending-command sweep; a `CKQuery` would need queryable indexes this
        // container does not define.
        var allStateRecords: [CKRecord] = []
        var changeToken: CKServerChangeToken?
        while true {
            do {
                let zoneChanges = try await database.recordZoneChanges(
                    inZoneWith: SyncConstants.stateZoneID,
                    since: changeToken
                )
                allStateRecords.append(contentsOf: zoneChanges.modificationResultsByID.values.compactMap { try? $0.get().record })
                guard zoneChanges.moreComing else { break }
                changeToken = zoneChanges.changeToken
            } catch {
                if SyncHealthDiagnostics.isExpectedMissingZone(error) {
                    logger.info("Tab reconciliation skipped: state zone does not exist yet")
                } else {
                    logger.error("Tab reconciliation failed: \(error.localizedDescription, privacy: .public)")
                    applySyncFailure(error)
                }
                return true
            }
        }

        // Re-read the snapshot after the await: a publish may have refreshed
        // it during the read, and expected must reflect the newest view. The
        // rest of this function is synchronous, so no publish can interleave
        // between computing `expected` and queueing deletes.
        guard let snapshot = freshAuthoritativeSnapshot() else {
            logger.info("Tab reconciliation aborted: snapshot went stale during zone read")
            return true
        }

        // Mirror the publish path exactly: incognito/private tabs are filtered
        // out before record names are derived, so `expected` must match what
        // the publish would actually save.
        let publicSnapshotTabs = snapshot.tabs.filter { !Self.isIncognitoTab($0) }
        let expectedRecordIDs = Self.tabRecordIDs(from: publicSnapshotTabs, deviceID: deviceID)
        let expectedByBrowser = Dictionary(grouping: publicSnapshotTabs, by: \.browserName)

        let myTabRecords = allStateRecords.filter {
            $0.recordType == SyncedTab.recordType
                && $0.recordID.recordName.hasPrefix("\(deviceID)_")
        }

        let orphans = myTabRecords.filter { record in
            guard !expectedRecordIDs.contains(record.recordID) else { return false }
            // A record the publish is actively saving is a live tab, not an
            // orphan — the authoritative snapshot may simply not have caught up
            // yet, and deleting it would briefly hide an open tab on the phone.
            guard pendingRecordsToSave[record.recordID] == nil else { return false }
            // Safety: never delete a browser's records when that browser is
            // absent from the snapshot entirely — a partial fetch, not closed
            // tabs. (Tradeoff: stranded records of a genuinely empty browser
            // wait until that browser next reports tabs before being pruned;
            // that is the safer failure than wiping open tabs on a bad fetch.)
            let browser = record["browserName"] as? String ?? ""
            return expectedByBrowser[browser] != nil
        }
        let orphanIDs = Set(orphans.map(\.recordID))

        if !orphanIDs.isEmpty {
            for recordID in orphanIDs {
                pendingRecordsToSave.removeValue(forKey: recordID)
                serverRecordsByID.removeValue(forKey: recordID)
            }
            updatePublishedTabLedger(to: expectedRecordIDs, removingDeleted: orphanIDs)
            let orphanDeletes: [CKSyncEngine.PendingRecordZoneChange] = orphanIDs.map { .deleteRecord($0) }
            syncEngine.state.add(pendingRecordZoneChanges: orphanDeletes)
            logger.info("Tab reconciliation queued deletion of \(orphanIDs.count) orphaned tab records (server=\(myTabRecords.count) expected=\(expectedRecordIDs.count))")
            sendPendingChanges()
        } else {
            updatePublishedTabLedger(to: expectedRecordIDs, removingDeleted: [])
            logger.info("Tab reconciliation: server matches live snapshot (records=\(myTabRecords.count))")
        }

        // Retain server change tags so any later write updates rather than
        // re-creates a record. Orphans are being deleted — their tags are moot.
        for record in myTabRecords where !orphanIDs.contains(record.recordID) {
            serverRecordsByID[record.recordID] = record
        }
        applySyncSuccess()
        return true
    }

    /// The authoritative snapshot, only when it is hydrated and recent enough
    /// to trust for deletion decisions.
    private func freshAuthoritativeSnapshot() -> AuthoritativeLiveTabSnapshot? {
        let snapshot = BrowserTabService.shared.authoritativeLiveTabSnapshot
        guard snapshot.isHydrated,
              let fetchedAt = snapshot.lastFetchedAt,
              Date().timeIntervalSince(fetchedAt) < Self.maxSnapshotAgeForReconcile else {
            return nil
        }
        return snapshot
    }

    /// Brings the durable tab ledger in line with what now exists on the
    /// server: the current live set, minus the records the reconcile just
    /// deleted, plus any ledger-known records the reconcile could not safely
    /// touch (their browser is absent from the snapshot) so the normal publish
    /// path keeps retrying them.
    private func updatePublishedTabLedger(to expectedRecordIDs: Set<CKRecord.ID>, removingDeleted deletedIDs: Set<CKRecord.ID>) {
        lastPublishedTabIDs.formUnion(expectedRecordIDs)
        lastPublishedTabIDs.subtract(deletedIDs)
        Self.persistPublishedTabRecordIDs(lastPublishedTabIDs, deviceID: deviceID)
    }
}
