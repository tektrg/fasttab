import CloudKit
import FastTabSync
import Foundation

// MARK: - Tab Order Publishing

extension SyncService {
    /// Every tab order change lands here; `TabOrderPublishGate` decides whether it goes now
    /// or (titles only) at most every 30s with the latest titles.
    func updateTabOrder(_ slots: [OrderedTabSlot]) {
        switch tabOrderGate.decision(for: slots, now: Date()) {
        case .publishNow:
            tabOrderFlushTask?.cancel()
            tabOrderFlushTask = nil
            pendingTabOrderSlots = nil
            publishTabOrder(slots)
        case .publishAt(let due):
            pendingTabOrderSlots = slots
            guard tabOrderFlushTask == nil else { return }
            tabOrderFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
                guard let self, !Task.isCancelled else { return }
                self.tabOrderFlushTask = nil
                if let slots = self.pendingTabOrderSlots { self.publishTabOrder(slots) }
                self.pendingTabOrderSlots = nil
            }
        }
    }

    func publishTabOrder(_ slots: [OrderedTabSlot]) {
        guard let syncEngine else { return }

        let syncedSlots = slots.map { slot in
            SyncedOrderedSlot(
                slotID: slot.slotID,
                matchKey: slot.matchKey,
                title: slot.title,
                url: slot.url,
                browserName: slot.browserName,
                profileName: slot.profileName,
                state: slot.state.rawValue,
                ghostedAt: slot.ghostedAt,
                isPinned: slot.isPinned
            )
        }

        let tabOrder = SyncedTabOrder(deviceID: deviceID, slots: syncedSlots)
        guard tabOrder.contentHash != lastPublishedTabOrderHash else {
            return
        }

        let recordID = CKRecord.ID(recordName: tabOrder.id, zoneID: SyncConstants.stateZoneID)
        let record = serverRecordsByID[recordID].flatMap { tabOrder.applying(to: $0) }
            ?? tabOrder.toRecord(zoneID: SyncConstants.stateZoneID)

        pendingRecordsToSave[recordID] = record
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        lastPublishedTabOrderHash = tabOrder.contentHash
        tabOrderGate.didPublish(slots, at: Date())
        logger.info("Tab order sync queued: \(syncedSlots.count) slots (hash: \(tabOrder.contentHash.prefix(8), privacy: .public))")
        sendPendingChanges()
    }
}
