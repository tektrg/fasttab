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
    /// When a pass was last scheduled (gates the 10-minute retry of a same-host-set pass).
    var lastRunAt: Date?
    /// When a pass last actually started (spaces passes at least `faviconMinPassSpacing` apart).
    var lastPassStartedAt: Date?
    /// A detached lookup is running; a second pass must wait for it.
    var passInFlight = false
    /// Hosts no browser could give an icon for, so they aren't re-queried every pass.
    var failedLookups: [String: FaviconLookupFailure] = [:]
    /// Icons published so far. Kept when a tab closes, so closing/opening tabs
    /// does not rewrite a ~100 KB record; only a *new* host does.
    var retained: [String: Data] = [:]
    var task: Task<Void, Never>?
}

/// One browser's tab on a host: a page to look the icon up by in that browser's favicon store.
struct FaviconSource: Equatable {
    let browserName: String
    let url: String
}

struct FaviconCandidate: Equatable {
    let host: String
    /// Every browser that has a tab on the host (first page per browser, tab order);
    /// tried in order until one has an icon.
    let sources: [FaviconSource]
}

struct FaviconLookupFailure: Equatable {
    let at: Date
    /// The browsers that were tried, so a newly opened browser re-opens the lookup.
    let browsers: Set<String>
}

/// Publishes this Mac's `SyncedFavicons` (one record per Mac) so the phone's tab
/// list can show site icons. Icons come from the browsers' own favicon stores
/// (the same lookup the command bar uses), shrunk to a few hundred bytes each.
extension SyncService {
    /// How long a no-change host set waits before retrying hosts whose icon had
    /// not resolved yet (the browser may not have stored it at first sight).
    nonisolated static let faviconRetryInterval: TimeInterval = 10 * 60

    /// Passes are at least this far apart, however often live tabs change.
    nonisolated static let faviconMinPassSpacing: TimeInterval = 30
    /// A host nobody could resolve is not re-queried for this long.
    nonisolated static let faviconFailureBackoff: TimeInterval = 60 * 60

    /// One candidate per host, in tab order, web URLs only. Every browser with a tab on
    /// the host is kept (one page each) so a browser without the icon doesn't hide it.
    nonisolated static func faviconCandidates(
        from tabs: [(browserName: String, url: String)]
    ) -> [FaviconCandidate] {
        var order: [String] = []
        var sources: [String: [FaviconSource]] = [:]
        for tab in tabs {
            guard let host = SyncedFavicons.host(fromURL: tab.url) else { continue }
            if sources[host] == nil { order.append(host); sources[host] = [] }
            if !sources[host]!.contains(where: { $0.browserName == tab.browserName }) {
                sources[host]!.append(FaviconSource(browserName: tab.browserName, url: tab.url))
            }
        }
        return order.map { FaviconCandidate(host: $0, sources: sources[$0] ?? []) }
    }

    /// Lookups for attempt number `round` (0-based): each unresolved host's `round`-th
    /// source. A host with fewer sources drops out of later rounds.
    nonisolated static func faviconLookups(
        for candidates: [FaviconCandidate],
        round: Int,
        resolved: Set<String>
    ) -> [(host: String, source: FaviconSource)] {
        candidates.compactMap { candidate in
            guard !resolved.contains(candidate.host), candidate.sources.indices.contains(round) else { return nil }
            return (candidate.host, candidate.sources[round])
        }
    }

    /// Whether a previously failed host should be left alone: it failed within the
    /// backoff window and the browsers that could answer haven't changed.
    nonisolated static func shouldSkipFailedFavicon(
        _ failure: FaviconLookupFailure?,
        currentBrowsers: Set<String>,
        now: Date
    ) -> Bool {
        guard let failure else { return false }
        return failure.browsers == currentBrowsers
            && now.timeIntervalSince(failure.at) < faviconFailureBackoff
    }

    /// Seconds to wait before a pass: the 3 s debounce, stretched so passes start at
    /// least `faviconMinPassSpacing` after the previous one.
    nonisolated static func faviconPassDelay(lastPassStartedAt: Date?, now: Date) -> TimeInterval {
        let debounce: TimeInterval = 3
        guard let lastPassStartedAt else { return debounce }
        return max(debounce, faviconMinPassSpacing - now.timeIntervalSince(lastPassStartedAt))
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

        let delay = Self.faviconPassDelay(lastPassStartedAt: faviconPublishState.lastPassStartedAt, now: now)
        faviconPublishState.task?.cancel()
        faviconPublishState.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            // A cancelled predecessor may still be inside its detached lookup: never overlap it.
            while let self, self.faviconPublishState.passInFlight, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled, let self else { return }
            await self.runFaviconPass(candidates: candidates)
        }
    }

    private func runFaviconPass(candidates: [FaviconCandidate]) async {
        let now = Date()
        faviconPublishState.passInFlight = true
        faviconPublishState.lastPassStartedAt = now
        defer { faviconPublishState.passInFlight = false }

        let retained = faviconPublishState.retained
        let failures = faviconPublishState.failedLookups
        let missing = candidates.filter { candidate in
            retained[candidate.host] == nil
                && !Self.shouldSkipFailedFavicon(
                    failures[candidate.host],
                    currentBrowsers: Set(candidate.sources.map(\.browserName)),
                    now: now
                )
        }
        let backends = BrowserTabService.shared.backends

        let lookup: (icons: [String: Data], rawFetched: Int) = missing.isEmpty ? ([:], 0) : await Task.detached(priority: .utility) {
            Self.resolveFavicons(missing, backends: backends)
        }.value
        let resolved = lookup.icons
        guard !Task.isCancelled else { return }
        logger.info("Favicon pass: hosts=\(candidates.count) retained=\(retained.count) looked-up=\(missing.count) browser-returned=\(lookup.rawFetched) resolved=\(resolved.count)")

        for candidate in missing {
            if resolved[candidate.host] != nil {
                faviconPublishState.failedLookups.removeValue(forKey: candidate.host)
            } else {
                faviconPublishState.failedLookups[candidate.host] = FaviconLookupFailure(
                    at: now, browsers: Set(candidate.sources.map(\.browserName)))
            }
        }

        let current = candidates.compactMap { candidate -> (host: String, png: Data)? in
            guard let png = retained[candidate.host] ?? resolved[candidate.host] else { return nil }
            return (candidate.host, png)
        }
        let icons = SyncedFavicons.select(Self.mergedFaviconOrder(current: current, retained: retained))
        guard !icons.isEmpty else { return }
        queueFaviconsPublish(icons: icons)
    }

    /// Off-main: ask each browser's favicon store for each host, trying the host's
    /// browsers in order until one has an icon, then shrink the result.
    nonisolated private static func resolveFavicons(
        _ candidates: [FaviconCandidate],
        backends: [any BrowserBackend]
    ) -> (icons: [String: Data], rawFetched: Int) {
        var out: [String: Data] = [:]
        var rawFetched = 0
        let rounds = candidates.map { $0.sources.count }.max() ?? 0
        for round in 0..<rounds {
            let lookups = faviconLookups(for: candidates, round: round, resolved: Set(out.keys))
            for (browserName, group) in Dictionary(grouping: lookups, by: { $0.source.browserName }) {
                if Task.isCancelled { return (out, rawFetched) }
                guard let backend = backends.first(where: { $0.appName == browserName }) else { continue }
                let byURL = backend.fetchFaviconsBatch(pageURLs: group.map(\.source.url))
                for lookup in group {
                    guard let raw = byURL[lookup.source.url] else { continue }
                    rawFetched += 1
                    guard let png = FaviconImage.compactPNG(from: raw) else { continue }
                    out[lookup.host] = png
                }
            }
        }
        return (out, rawFetched)
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
