import Foundation
import CloudKit
import FastTabSync

/// Pure sync decision logic, split out of `SyncService`.
///
/// Every function here is `nonisolated static` and side-effect free. CloudKit
/// cannot be exercised in-process, so the rules that decide *what* to sync live
/// where they can be unit-tested directly, leaving the service itself to hold
/// state and talk to the network.
extension SyncService {
    /// How often this Mac republishes its `SyncedDevice` record so the phone can
    /// tell "awake" from "asleep". Must stay well under the phone's staleness
    /// threshold (600s) or a perfectly healthy Mac reports itself asleep. The
    /// cost is one small record write per interval, which is nothing next to the
    /// 15s fetch poll that already runs.
    nonisolated private static let deviceHeartbeatInterval: TimeInterval = 3 * 60

    nonisolated static func isIncognitoTab(_ tab: BrowserSearchResult) -> Bool {
        let lowerProfile = (tab.profileName ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowerProfile == "incognito" || lowerProfile == "private" || lowerProfile.hasPrefix("incognito ") || lowerProfile.hasPrefix("private ") {
            return true
        }

        let lowerWindow = (tab.windowName ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Only match recognized browser private/incognito window identifiers (exact names or specific phrases).
        // NEVER match arbitrary loose substrings like "tor" or "private" which match regular webpage titles
        // (e.g. "Chrome Web Store", "History of macOS", "Private Repo", "VS Code Editor", "Tutorial", "Vector").
        let knownPrivateWindowNames: Set<String> = [
            "incognito",
            "incognito window",
            "private browsing",
            "inprivate",
            "inprivate browsing",
            "inprivate window",
            "private window",
            "private with tor",
            "private window with tor"
        ]
        if knownPrivateWindowNames.contains(lowerWindow) {
            return true
        }

        return false
    }

    nonisolated static func sanitizeRecordName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
            .map(String.init)
            .joined()
    }

    /// The CloudKit record name for one live tab. The snapshot source decides
    /// the identity: the extension path keys by stable tab ID, while the
    /// AppleScript fallback has no tab ID and keys by window/tab position.
    /// Kept as the single source of truth so the publish path, the content
    /// fingerprint, and the state-zone reconciliation all agree on a tab's
    /// record identity.
    nonisolated static func tabRecordName(
        deviceID: String,
        browserName: String,
        windowIndex: Int?,
        tabIndex: Int?,
        tabID: Int?,
        fallbackIndex: Int
    ) -> String {
        let tabSlug: String
        if let tabID {
            tabSlug = "tab_\(tabID)"
        } else {
            tabSlug = "win\(windowIndex ?? 0)_idx\(tabIndex ?? fallbackIndex)"
        }
        return sanitizeRecordName("\(deviceID)_\(browserName)_\(tabSlug)")
    }

    /// The set of record IDs the given live-tab snapshot maps to. The
    /// enumerated position is the last-resort fallback when neither tabID nor
    /// tabIndex is present, matching `tabRecordName`'s contract.
    nonisolated static func tabRecordIDs(
        from tabs: [BrowserSearchResult],
        deviceID: String
    ) -> Set<CKRecord.ID> {
        Set(tabs.enumerated().map { index, tab in
            CKRecord.ID(
                recordName: tabRecordName(
                    deviceID: deviceID,
                    browserName: tab.browserName,
                    windowIndex: tab.windowIndex,
                    tabIndex: tab.tabIndex,
                    tabID: tab.tabID,
                    fallbackIndex: index
                ),
                zoneID: SyncConstants.stateZoneID
            )
        })
    }

    nonisolated static func tabRecordIDsToDelete(
        previouslyPublished: Set<CKRecord.ID>,
        currentlyPublished: Set<CKRecord.ID>
    ) -> Set<CKRecord.ID> {
        previouslyPublished.subtracting(currentlyPublished)
    }

    nonisolated static func tabRecordLedgerAfterPublishing(
        remotelyKnown: Set<CKRecord.ID>,
        currentlyPublished: Set<CKRecord.ID>
    ) -> Set<CKRecord.ID> {
        remotelyKnown.union(currentlyPublished)
    }

    nonisolated static func tabRecordLedgerAfterAcknowledgingDeletions(
        remotelyKnown: Set<CKRecord.ID>,
        deletedRecordIDs: Set<CKRecord.ID>
    ) -> Set<CKRecord.ID> {
        remotelyKnown.subtracting(deletedRecordIDs)
    }

    nonisolated static func shouldProcessIncomingCommand(_ command: SyncCommand) -> Bool {
        command.status == .pending
    }

    /// Whether a command is past the point of being actionable.
    ///
    /// Named and exposed rather than inlined because
    /// `SyncCommandJournal.retainedSettledResponses` depends on it being the
    /// *first* gate in `handleIncomingCommand`: that ordering is the whole
    /// reason the anti-replay ledger can safely forget an expired command — an
    /// expired duplicate is answered `.expired` and never reaches the ledger.
    nonisolated static func hasExpired(_ command: SyncCommand, now: Date = Date()) -> Bool {
        command.expiresAt <= now
    }

    nonisolated static func shouldRequestRecordRetrySend(
        queuedSaveRetry: Bool,
        queuedDeleteRetry: Bool
    ) -> Bool {
        queuedSaveRetry || queuedDeleteRetry
    }

    nonisolated static func terminalResponseForInterruptedCommand(
        _ command: SyncCommand,
        completedAt: Date = Date()
    ) -> SyncCommand? {
        guard command.kind != .closeTab else { return nil }
        var response = command
        response.status = .refused
        response.statusReason = "Interrupted before completion; resend command"
        response.completedAt = completedAt
        return response
    }

    nonisolated static func shouldPublishDeviceHeartbeat(
        lastPublishedAt: Date?,
        now: Date,
        interval: TimeInterval = deviceHeartbeatInterval
    ) -> Bool {
        guard let lastPublishedAt else { return true }
        return now.timeIntervalSince(lastPublishedAt) >= interval
    }

    nonisolated static func recordForRetry(
        intendedRecord: CKRecord,
        error: Error
    ) -> CKRecord? {
        guard let cloudKitError = error as? CKError,
              cloudKitError.code == .serverRecordChanged,
              let serverRecord = cloudKitError.serverRecord,
              serverRecord.recordID == intendedRecord.recordID,
              serverRecord.recordType == intendedRecord.recordType else {
            return nil
        }

        switch intendedRecord.recordType {
        case SyncCommand.recordType:
            guard let intendedCommand = SyncCommand(from: intendedRecord) else { return nil }
            return intendedCommand.applying(to: serverRecord)
        case SyncedTab.recordType:
            guard let intendedTab = SyncedTab(from: intendedRecord) else { return nil }
            return intendedTab.applying(to: serverRecord)
        case SyncedDevice.recordType:
            guard let intendedDevice = SyncedDevice(from: intendedRecord) else { return nil }
            return intendedDevice.applying(to: serverRecord)
        case SyncedBookmarkBlob.recordType:
            guard let intendedBookmarks = SyncedBookmarkBlob(from: intendedRecord) else { return nil }
            return intendedBookmarks.applying(to: serverRecord)
        case SyncedHistorySlice.recordType:
            guard let intendedHistory = SyncedHistorySlice(from: intendedRecord) else { return nil }
            return intendedHistory.applying(to: serverRecord)
        default:
            return nil
        }
    }

    nonisolated static func loadPublishedTabRecordIDs(
        deviceID: String,
        defaults: UserDefaults = .standard
    ) -> Set<CKRecord.ID> {
        let recordNames = defaults.stringArray(forKey: publishedTabRecordNamesDefaultsKey(deviceID: deviceID)) ?? []
        return Set(recordNames.map {
            CKRecord.ID(recordName: $0, zoneID: SyncConstants.stateZoneID)
        })
    }

    nonisolated static func persistPublishedTabRecordIDs(
        _ recordIDs: Set<CKRecord.ID>,
        deviceID: String,
        defaults: UserDefaults = .standard
    ) {
        let key = publishedTabRecordNamesDefaultsKey(deviceID: deviceID)
        guard !recordIDs.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(recordIDs.map(\.recordName).sorted(), forKey: key)
    }

    nonisolated private static func publishedTabRecordNamesDefaultsKey(deviceID: String) -> String {
        "FastTab.PublishedTabRecordNames.\(deviceID)"
    }

    /// Lightweight content fingerprint for a set of tabs. Changes whenever a
    /// tab is opened, closed, navigated, or renamed. Uses `.hashValue` on a
    /// concatenated identity string — fast, no crypto dependency, sufficient
    /// for in-memory same-process diffing (not persisted across launches).
    nonisolated static func tabContentFingerprint(_ tabs: [BrowserSearchResult]) -> String {
        // Sort by a stable key so reordering alone doesn't trigger a re-sync.
        var hasher = Hasher()
        hasher.combine(tabs.count)
        // A tab's CloudKit identity depends on its snapshot source. The
        // extension path names records by stable tab ID, where a pure reorder
        // is a no-op and must NOT re-sync. The AppleScript fallback names them
        // by window/tab position, so a reorder there changes the record-name
        // set and MUST trigger a re-sync — otherwise the old positional records
        // are never deleted and closed tabs linger on the phone. Encoding that
        // difference keeps the skip decision aligned with what would actually
        // be published.
        let sorted = tabs.map { tab -> String in
            if let tabID = tab.tabID {
                return "\(tab.browserName)|\(tab.url)|\(tab.title)|\(tabID)"
            }
            return "\(tab.browserName)|\(tab.url)|\(tab.title)|-1|\(tab.windowIndex ?? -1)|\(tab.tabIndex ?? -1)"
        }.sorted()
        for entry in sorted {
            hasher.combine(entry)
        }
        return String(hasher.finalize())
    }
}
