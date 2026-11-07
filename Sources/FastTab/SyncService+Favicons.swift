import Foundation
import CloudKit
import FastTabSync

/// In-memory bookkeeping for the favicon publish. Not persisted: after a
/// relaunch the first pass republishes once.
struct FaviconPublishState {
    /// Fingerprint of the last queued icon set; `nil` forces the next publish.
    var lastPublishedFingerprint: String?
    /// Sorted host list of the last pass that was scheduled.
    var lastSignature: String?
    var lastRunAt: Date?
    /// Icons published so far. Kept when a tab closes, so closing/opening tabs
    /// does not rewrite a ~100 KB record; only a *new* host does.
    var retained: [String: Data] = [:]
    var task: Task<Void, Never>?
}

struct FaviconCandidate: Equatable {
    let host: String
    let browserName: String
    /// A representative page of that host, used for the favicon-DB lookup.
    let url: String
}

/// Publishes this Mac's `SyncedFavicons` (one record per Mac) so the phone's tab
/// list can show site icons. Icons come from the browsers' own favicon stores
/// (the same lookup the command bar uses), shrunk to a few hundred bytes each.
extension SyncService {
    /// How long a no-change host set waits before retrying hosts whose icon had
    /// not resolved yet (the browser may not have stored it at first sight).
    nonisolated static let faviconRetryInterval: TimeInterval = 10 * 60
    nonisolated static let faviconDebounce: Duration = .seconds(3)

    /// One candidate per host, in tab order, web URLs only.
    nonisolated static func faviconCandidates(
        from tabs: [(browserName: String, url: String)]
    ) -> [FaviconCandidate] {
        var seen = Set<String>()
        var out: [FaviconCandidate] = []
        for tab in tabs {
            guard let host = SyncedFavicons.host(fromURL: tab.url), seen.insert(host).inserted else { continue }
            out.append(FaviconCandidate(host: host, browserName: tab.browserName, url: tab.url))
        }
        return out
    }

    nonisolated static func shouldRunFaviconPass(
        signature: String,
        lastSignature: String?,
        lastRunAt: Date?,
        now: Date
    ) -> Bool {
        guard signature == lastSignature, let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= faviconRetryInterval
    }

    /// Current hosts first (tab order), then icons kept from closed tabs
    /// (alphabetical, so the set is deterministic).
    nonisolated static func mergedFaviconOrder(
        current: [(host: String, png: Data)],
        retained: [String: Data]
    ) -> [(host: String, png: Data)] {
        let currentHosts = Set(current.map(\.host))
        let kept = retained
            .filter { !currentHosts.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { (host: $0.key, png: $0.value) }
        return current + kept
    }

    /// Entry point, called with every live-tab snapshot. Cheap when the host set
    /// is unchanged; otherwise debounces, resolves missing icons off the main
    /// thread and queues a record only if the icon set actually changed.
    func requestFaviconsPublish(for tabs: [BrowserSearchResult], now: Date = Date()) {
        guard syncEngine != nil else { return }
        let candidates = Self.faviconCandidates(
            from: tabs.filter { !Self.isIncognitoTab($0) }.map { ($0.browserName, $0.url) }
        )
        guard !candidates.isEmpty else { return }

        let signature = candidates.map(\.host).sorted().joined(separator: ",")
        guard Self.shouldRunFaviconPass(
            signature: signature,
            lastSignature: faviconPublishState.lastSignature,
            lastRunAt: faviconPublishState.lastRunAt,
            now: now
        ) else { return }
        faviconPublishState.lastSignature = signature
        faviconPublishState.lastRunAt = now

        faviconPublishState.task?.cancel()
        faviconPublishState.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.faviconDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.runFaviconPass(candidates: candidates)
        }
    }

    private func runFaviconPass(candidates: [FaviconCandidate]) async {
        let retained = faviconPublishState.retained
        let missing = candidates.filter { retained[$0.host] == nil }
        let backends = BrowserTabService.shared.backends

        let resolved: [String: Data] = missing.isEmpty ? [:] : await Task.detached(priority: .utility) {
            Self.resolveFavicons(missing, backends: backends)
        }.value
        guard !Task.isCancelled else { return }

        let current = candidates.compactMap { candidate -> (host: String, png: Data)? in
            guard let png = retained[candidate.host] ?? resolved[candidate.host] else { return nil }
            return (candidate.host, png)
        }
        let icons = SyncedFavicons.select(Self.mergedFaviconOrder(current: current, retained: retained))
        guard !icons.isEmpty else { return }
        queueFaviconsPublish(icons: icons)
    }

    /// Off-main: ask each browser's favicon store for the representative page of
    /// each missing host, then shrink the result.
    nonisolated private static func resolveFavicons(
        _ candidates: [FaviconCandidate],
        backends: [any BrowserBackend]
    ) -> [String: Data] {
        var out: [String: Data] = [:]
        for (browserName, group) in Dictionary(grouping: candidates, by: \.browserName) {
            if Task.isCancelled { break }
            guard let backend = backends.first(where: { $0.appName == browserName }) else { continue }
            let byURL = backend.fetchFaviconsBatch(pageURLs: group.map(\.url))
            for candidate in group {
                guard let raw = byURL[candidate.url],
                      let png = FaviconImage.compactPNG(from: raw) else { continue }
                out[candidate.host] = png
            }
        }
        return out
    }

    private func queueFaviconsPublish(icons: [String: Data]) {
        guard let syncEngine else { return }
        let favicons = SyncedFavicons(deviceID: deviceID, icons: icons)
        guard favicons.fingerprint != faviconPublishState.lastPublishedFingerprint else { return }

        let recordID = CKRecord.ID(recordName: favicons.id, zoneID: SyncConstants.stateZoneID)
        guard let record = serverRecordsByID[recordID].flatMap({ favicons.applying(to: $0) })
                ?? favicons.toRecord(zoneID: SyncConstants.stateZoneID) else {
            logger.error("Favicons not published: record too large (\(icons.count) icons)")
            return
        }

        faviconPublishState.lastPublishedFingerprint = favicons.fingerprint
        faviconPublishState.retained = icons
        pendingRecordsToSave[record.recordID] = record
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
        logger.info("Favicons queued: \(icons.count) icons")
        sendPendingChanges()
    }

    /// Forget what was published (server deletion, account change) so the next
    /// snapshot republishes.
    func resetFaviconPublishState() {
        faviconPublishState.task?.cancel()
        faviconPublishState = FaviconPublishState()
    }
}
