import Foundation
import CloudKit
import OSLog
import FastTabSync

// The engine's own fetch only reaches a zone after a CloudKit push marks it dirty, and
// pushes do not reliably arrive. Without this sweep a phone could sit on a Mac's
// heartbeat from a day ago ("Mac offline — last seen 1 day ago") while the Mac was
// publishing every 3 minutes. Same remedy the Mac uses (`catchUpReaderZone`): read
// each zone ourselves with a saved change token, so each sweep only moves what changed.

extension SyncConsumer {
    private static let sweptZones = [
        SyncConstants.stateZoneID,
        SyncConstants.commandsZoneID,
        SyncConstants.readerZoneID
    ]

    /// Poll-tick entry: sweeps at most once per `ZoneSweepSchedule.interval`.
    func sweepZonesIfDue() async {
        guard ZoneSweepSchedule.isDue(lastSweptAt: lastZoneSweepAt, now: Date()) else { return }
        await sweepZones()
    }

    /// Reads every zone's changes since the last sweep and applies them like an engine fetch.
    func sweepZones() async {
        guard !zoneSweepInFlight else { return }
        zoneSweepInFlight = true
        defer { zoneSweepInFlight = false }
        lastZoneSweepAt = Date()

        for zoneID in Self.sweptZones {
            await sweep(zoneID)
        }
    }

    private func sweep(_ zoneID: CKRecordZone.ID) async {
        let tokenURL = Self.tokenURL(for: zoneID)
        var token = (try? Data(contentsOf: tokenURL)).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        do {
            while true {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
                let records = changes.modificationResultsByID.values.compactMap { try? $0.get().record }
                let deletions = changes.deletions.map(\.recordID)
                if !records.isEmpty || !deletions.isEmpty {
                    await applyFetchedChanges(modifications: records, deletions: deletions)
                }
                token = changes.changeToken
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: changes.changeToken, requiringSecureCoding: true) {
                    try? data.write(to: tokenURL, options: .atomic)
                }
                guard changes.moreComing else { break }
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            // Start over from scratch next time.
            try? FileManager.default.removeItem(at: tokenURL)
        } catch let error as CKError where error.code == .zoneNotFound {
            // Zone not created yet (nothing has been written to it).
        } catch {
            guard !ZoneSweepSchedule.isCancellation(error) else { return }
            markSyncFailed(error, whileDoing: "sweeping \(zoneID.zoneName)")
        }
    }

    /// A different iCloud account has different zones: forget where we were.
    func resetZoneSweepTokens() {
        for zoneID in Self.sweptZones {
            try? FileManager.default.removeItem(at: Self.tokenURL(for: zoneID))
        }
        lastZoneSweepAt = nil
    }

    private static func tokenURL(for zoneID: CKRecordZone.ID) -> URL {
        AppGroupContainer.fileURL(forFileNamed: "zone_sweep_token_\(zoneID.zoneName).dat")
    }
}
