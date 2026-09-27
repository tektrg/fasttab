import Foundation
import CloudKit
import IndieMetrics
import FastTabSync

/// In-memory bookkeeping for the tab-stats publish. Not persisted: after a
/// relaunch the first check republishes once, which is cheap.
struct TabStatsPublishState {
    /// Fingerprint of the last queued digest; `nil` forces the next publish.
    var lastPublishedFingerprint: Int?
    var lastCheckedAt: Date?
    var isChecking = false
}

/// Publishes this Mac's `SyncedTabStats` digest (one record per Mac; the phone
/// sums across Macs). At most one check per `tabStatsCheckInterval`, and a
/// record write only when the digest actually changed.
extension SyncService {
    nonisolated static let tabStatsCheckInterval: TimeInterval = 60 * 60

    nonisolated static func isTabStatsCheckDue(lastCheckedAt: Date?, now: Date) -> Bool {
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= tabStatsCheckInterval
    }

    nonisolated static func tabStatsFingerprint(days: [TabDay], timeZoneID: String) -> Int {
        var hasher = Hasher()
        hasher.combine(timeZoneID)
        hasher.combine(days)
        return hasher.finalize()
    }

    /// Called after each batch of tab metric events is written.
    func publishTabStatsIfDue(eventLog: some MetricEventStoring, now: Date = Date()) {
        guard syncEngine != nil,
              !tabStatsPublishState.isChecking,
              Self.isTabStatsCheckDue(lastCheckedAt: tabStatsPublishState.lastCheckedAt, now: now) else { return }
        tabStatsPublishState.isChecking = true
        tabStatsPublishState.lastCheckedAt = now
        let calendar = Calendar.current

        Task { @MainActor in
            defer { self.tabStatsPublishState.isChecking = false }
            let days: [TabDay]
            do {
                let events = try await eventLog.loadEvents()
                days = await Task.detached(priority: .utility) {
                    TabStatsDigestBuilder.days(from: events, calendar: calendar, now: now)
                }.value
            } catch {
                self.logger.error("Tab stats digest skipped; metric log unreadable: \(error.localizedDescription, privacy: .public)")
                return
            }
            self.queueTabStatsPublish(days: days, timeZoneID: calendar.timeZone.identifier, updatedAt: now)
        }
    }

    private func queueTabStatsPublish(days: [TabDay], timeZoneID: String, updatedAt: Date) {
        guard let syncEngine, !days.isEmpty else { return }
        let fingerprint = Self.tabStatsFingerprint(days: days, timeZoneID: timeZoneID)
        guard fingerprint != tabStatsPublishState.lastPublishedFingerprint else { return }

        let stats = SyncedTabStats(deviceID: deviceID, timeZoneID: timeZoneID, days: days, updatedAt: updatedAt)
        let recordID = CKRecord.ID(recordName: stats.id, zoneID: SyncConstants.stateZoneID)
        guard let record = serverRecordsByID[recordID].flatMap({ stats.applying(to: $0) })
                ?? stats.toRecord(zoneID: SyncConstants.stateZoneID) else { return }

        tabStatsPublishState.lastPublishedFingerprint = fingerprint
        pendingRecordsToSave[record.recordID] = record
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        logger.info("Tab stats queued: \(days.count) days")
        sendPendingChanges()
    }

    /// Forget what was published (server deletion, account change), so the next
    /// snapshot republishes without waiting out the hourly gate.
    func resetTabStatsPublishState() {
        tabStatsPublishState.lastPublishedFingerprint = nil
        tabStatsPublishState.lastCheckedAt = nil
    }
}
