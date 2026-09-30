import Foundation
import FastTabSync

/// Pure half of the live sync probe (`scripts/sync-probe.sh`): parses a probe
/// request, filters what the server holds down to the probe's own marker tab,
/// and writes the answer file. The CloudKit read lives in
/// `SyncService+ServerProbe.swift`.
///
/// Server truth: the probe reads `StateZoneMirror` (shared with the tab
/// reconcile), which follows its own change token, independent of
/// CKSyncEngine's token and of the publish ledger — it only ever sees what
/// CloudKit reports.
///
/// Transport: the script posts a distributed notification and reads the
/// answer from a 0600 file inside a 0700 directory under this user's
/// Application Support. The request carries no authority — answering it is
/// read-only (no saves, deletes, ledger or health changes) — and the answer
/// only lists this device's tab records whose URL contains the requested
/// marker, so it never dumps the user's tab list.
enum SyncServerProbe {
    nonisolated static let requestNotificationName = Notification.Name("com.trungluong.FastTab.syncProbe.request")
    nonisolated static let requestIDKey = "requestID"
    nonisolated static let urlMarkerKey = "urlMarker"

    /// Every marker must start with the probe's own query key
    /// (`scripts/sync-probe.sh`), so only probe URLs can ever match — a
    /// generic marker like "https://www." would otherwise list real tabs.
    nonisolated static let urlMarkerPrefix = "fasttab-sync-probe="
    /// Short enough to never be a URL dump; long enough to be unique.
    nonisolated static let urlMarkerLengthRange = 12...200
    nonisolated static let requestIDMaxLength = 64

    struct Request: Equatable, Sendable {
        var requestID: String
        var urlMarker: String
    }

    /// One state-zone record, reduced to what the probe needs.
    struct ServerRecordSummary: Equatable, Sendable {
        var recordType: String
        var recordName: String
        var browserName: String
        var url: String?
    }

    /// How one change-feed catch-up ended. A request arriving within
    /// `catchUpReuseWindow` of the previous catch-up is answered from it
    /// (the mirror is at most that old), so a request flood cannot turn into
    /// a flood of CloudKit reads.
    struct CatchUpResult: Equatable, Sendable {
        var outcome: Outcome
        var errorMessage: String?
        var finishedAt: Date
    }

    nonisolated static let catchUpReuseWindow: TimeInterval = 2

    nonisolated static func reusableCatchUp(_ previous: CatchUpResult?, now: Date) -> CatchUpResult? {
        guard let previous, now.timeIntervalSince(previous.finishedAt) < catchUpReuseWindow else { return nil }
        return previous
    }

    /// The shared mirror holds entries the feed reported but could not
    /// deliver (one could be the probe's own tab), so the answer would not be
    /// the server's full truth. Clears when those records next change or at
    /// the mirror's next full walk.
    struct UnreadableChangeFeedEntries: LocalizedError, Equatable {
        var unreadableRecordCount: Int
        var errorDescription: String? {
            "change feed holds \(unreadableRecordCount) unreadable record(s); try again later"
        }
    }

    struct MatchingTab: Codable, Equatable, Sendable {
        var recordName: String
        var browserName: String
        var url: String
    }

    enum Outcome: String, Codable, Sendable {
        /// The zone was read in full; `matchingTabs` is the server's truth.
        case ok
        /// The state zone does not exist yet (nothing ever published).
        case zoneMissing = "zone-missing"
        /// The read failed; `matchingTabs` is empty and means nothing.
        case error
    }

    struct Response: Codable, Equatable, Sendable {
        var requestID: String
        var completedAt: Date
        var deviceID: String
        var syncHealth: String
        var outcome: Outcome
        var errorMessage: String?
        var thisDeviceTabRecordCount: Int
        var matchingTabs: [MatchingTab]
    }

    /// Validates an untrusted notification payload. Nil = ignore the request.
    nonisolated static func parseRequest(userInfo: [AnyHashable: Any]?) -> Request? {
        guard let requestID = userInfo?[requestIDKey] as? String,
              let urlMarker = userInfo?[urlMarkerKey] as? String else { return nil }
        let requestIDCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !requestID.isEmpty,
              requestID.count <= requestIDMaxLength,
              requestID.unicodeScalars.allSatisfy({ requestIDCharacters.contains($0) && $0.isASCII }) else { return nil }
        guard urlMarkerLengthRange.contains(urlMarker.count),
              urlMarker.hasPrefix(urlMarkerPrefix),
              urlMarker.count > urlMarkerPrefix.count,
              !urlMarker.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        return Request(requestID: requestID, urlMarker: urlMarker)
    }

    /// Same ownership rule as the publish ledger and reconcile: a device's tab
    /// records are named `<deviceID>_...`.
    nonisolated static func isThisDevicesTabRecord(_ record: ServerRecordSummary, deviceID: String) -> Bool {
        record.recordType == SyncedTab.recordType && record.recordName.hasPrefix("\(deviceID)_")
    }

    nonisolated static func makeResponse(
        request: Request,
        deviceID: String,
        syncHealth: SyncHealth,
        outcome: Outcome,
        errorMessage: String? = nil,
        serverRecords: [ServerRecordSummary],
        completedAt: Date
    ) -> Response {
        let myTabRecords = serverRecords.filter { isThisDevicesTabRecord($0, deviceID: deviceID) }
        let matchingTabs = myTabRecords.compactMap { record -> MatchingTab? in
            guard let url = record.url, url.contains(request.urlMarker) else { return nil }
            return MatchingTab(recordName: record.recordName, browserName: record.browserName, url: url)
        }
        return Response(
            requestID: request.requestID,
            completedAt: completedAt,
            deviceID: deviceID,
            syncHealth: healthLabel(syncHealth),
            outcome: outcome,
            errorMessage: errorMessage,
            thisDeviceTabRecordCount: myTabRecords.count,
            matchingTabs: matchingTabs.sorted { $0.recordName < $1.recordName }
        )
    }

    /// Stable labels the script matches on (`ok` = healthy).
    nonisolated static func healthLabel(_ health: SyncHealth) -> String {
        switch health {
        case .unknown: return "unknown"
        case .ok: return "ok"
        case .noAccount: return "no-account"
        case .restricted: return "restricted"
        case .failing(let message): return "failing: \(message)"
        }
    }

    nonisolated static func responseFileURL(fastTabSupportDirectory: URL) -> URL {
        fastTabSupportDirectory
            .appendingPathComponent("sync-probe", isDirectory: true)
            .appendingPathComponent("server-tabs.json")
    }

    /// Atomic write; directory 0700 and file 0600 so only this Mac user reads it.
    nonisolated static func writeResponse(_ response: Response, to fileURL: URL) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(response).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
