import Foundation
import SwiftUI
import Combine
import FastTabSync

public enum EmergingItemSource: Hashable, Sendable {
    case bookmark(bookmark: SyncedBookmarkItem, browserName: String, profileName: String?, deviceID: String)
    case tab(tab: SyncedTab)
    case generic
}

/// Which of the feed's two lanes an item was pulled into. Drives the badge
/// label so the reason a card is here is always legible.
public enum EmergingLane: String, Sendable {
    case forgotten = "Forgotten"
    case pickUp = "Pick up"
}

public struct EmergingItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let domain: String
    public let badgeText: String
    public let reason: String?
    public let source: EmergingItemSource
    public let lane: EmergingLane

    public init(
        id: String,
        title: String,
        url: URL,
        domain: String,
        badgeText: String,
        reason: String? = nil,
        source: EmergingItemSource = .generic,
        lane: EmergingLane = .forgotten
    ) {
        self.id = id
        self.title = title.isEmpty ? domain : title
        self.url = url
        self.domain = domain
        self.badgeText = badgeText
        self.reason = reason
        self.source = source
        self.lane = lane
    }
}

/// A candidate before ranking: everything needed to score it, deduped by
/// `EmergingURLUtils.dedupeKey`.
private struct EmergingCandidate {
    let dedupeKey: String
    let title: String
    let url: URL
    let host: String
    let ageInDays: Double?
    let visitCount: Int
    let topicScore: Double
    let topicName: String?
    let make: () -> EmergingItem
}

@MainActor
public final class EmergingContentProvider: ObservableObject {
    public static let shared = EmergingContentProvider()

    @Published public private(set) var items: [EmergingItem] = []
    @Published public private(set) var isProcessing: Bool = false

    public func removeItem(id: String) {
        items.removeAll { $0.id == id }
    }

    /// "Not a read" — hides this one link going forward and drops it from
    /// the feed immediately.
    public func markLinkNotARead(_ item: EmergingItem) {
        EmergingDismissalStore.shared.dismissLink(url: item.url)
        removeItem(id: item.id)
    }

    /// "Not a read" — hides the whole website going forward and drops every
    /// currently-shown card from that host.
    public func markHostNotARead(_ item: EmergingItem) {
        EmergingDismissalStore.shared.dismissHost(url: item.url)
        let host = (item.url.host() ?? "").lowercased()
        items.removeAll { ($0.url.host() ?? "").lowercased() == host }
    }

    nonisolated private static let forgottenTarget = 6
    nonisolated private static let pickUpTarget = 4
    nonisolated private static let maxPerTopic = 2
    nonisolated private static let maxPerHost = 2
    nonisolated private static let forgottenBookmarkAgeDays: Double = 30
    nonisolated private static let forgottenTabIdleDays: Double = 3
    nonisolated private static let pickUpRecentDays: Double = 3
    nonisolated private static let ownReadWindowDays: Double = 7

    private var stateCancellable: AnyCancellable?
    private var activeTask: Task<Void, Never>?

    private init() {
        refresh()

        stateCancellable = LocalCache.shared.$state
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
    }

    public func refresh() {
        activeTask?.cancel()
        isProcessing = true

        let state = LocalCache.shared.state
        let lastOpened = LastOpenedStore.shared.items
        let dismissedHosts = EmergingDismissalStore.shared.dismissedHosts
        let dismissedLinkKeys = EmergingDismissalStore.shared.dismissedLinkKeys
        let classificationCache = EmergingLinkClassifier.shared.cacheSnapshot()

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let computed = Self.computeRecommendations(
                state: state,
                lastOpened: lastOpened,
                dismissedHosts: dismissedHosts,
                dismissedLinkKeys: dismissedLinkKeys,
                classificationCache: classificationCache
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.items = computed
                self?.isProcessing = false
            }

            // Kick off (uncached) classification for whatever made the cut, so
            // the next refresh can act on a verdict. Best-effort, not awaited
            // by the feed itself.
            for item in computed {
                await EmergingLinkClassifier.shared.classify(title: item.title, url: item.url)
            }
        }
    }

    private nonisolated static func computeRecommendations(
        state: CachedSyncState,
        lastOpened: [LastOpenedItem],
        dismissedHosts: Set<String>,
        dismissedLinkKeys: Set<String>,
        classificationCache: [String: Bool]
    ) -> [EmergingItem] {
        let now = Date()

        // Anything read on the iPhone recently shouldn't come back as "new".
        var recentlyReadOnPhoneKeys = Set<String>()
        for opened in lastOpened where now.timeIntervalSince(opened.openedAt) < Self.ownReadWindowDays * 86400 {
            if let u = URL(string: opened.url) {
                recentlyReadOnPhoneKeys.insert(EmergingURLUtils.dedupeKey(u))
            }
        }

        func isSuppressed(_ url: URL) -> Bool {
            let host = (url.host() ?? "").lowercased()
            if dismissedHosts.contains(host) { return true }
            let key = EmergingURLUtils.dedupeKey(url)
            if dismissedLinkKeys.contains(key) { return true }
            if recentlyReadOnPhoneKeys.contains(key) { return true }
            return false
        }

        // MARK: Topic model — what this week's browsing is "about".
        // Built from open tabs + last 7 days of history, weighted toward
        // recency so a topic you've moved on from stops boosting old links.
        var topicWeightByHost: [String: Double] = [:]
        var topicWeightByKeyword: [String: Double] = [:]

        func recencyWeight(_ date: Date) -> Double {
            let ageDays = max(0, now.timeIntervalSince(date) / 86400)
            return max(0.1, 1.0 - ageDays / 7.0)
        }

        for tab in state.tabs {
            guard let host = URL(string: tab.url)?.host()?.lowercased(), !host.isEmpty else { continue }
            let weight = recencyWeight(tab.timestamp.timeIntervalSince1970 > 0 ? tab.timestamp : now)
            topicWeightByHost[host, default: 0] += weight
            for kw in extractTopicKeywords(from: tab.title) {
                topicWeightByKeyword[kw, default: 0] += weight
            }
        }
        for slice in state.historySlices {
            for entry in slice.entries {
                guard now.timeIntervalSince(entry.lastVisitedAt) < 7 * 86400 else { continue }
                guard let host = URL(string: entry.url)?.host()?.lowercased(), !host.isEmpty else { continue }
                let weight = recencyWeight(entry.lastVisitedAt)
                topicWeightByHost[host, default: 0] += weight
                for kw in extractTopicKeywords(from: entry.title) {
                    topicWeightByKeyword[kw, default: 0] += weight
                }
            }
        }

        // Words that show up across most of the week's pages aren't a topic,
        // they're noise (a company name in every internal tool's title, etc).
        let totalWeightedPages = Double(state.tabs.count + state.historySlices.reduce(0) { $0 + $1.entries.count })
        if totalWeightedPages > 0 {
            let noisyThreshold = totalWeightedPages * 0.15
            for (kw, weight) in topicWeightByKeyword where weight > noisyThreshold {
                topicWeightByKeyword.removeValue(forKey: kw)
            }
        }

        func topicAffinity(host: String, title: String) -> (score: Double, name: String?) {
            var score = topicWeightByHost[host] ?? 0
            var bestKeyword: String?
            var bestKeywordWeight = 0.0
            for kw in extractTopicKeywords(from: title) {
                if let w = topicWeightByKeyword[kw], w > bestKeywordWeight {
                    bestKeywordWeight = w
                    bestKeyword = kw
                }
            }
            score += bestKeywordWeight
            let name: String? = bestKeyword?.capitalized ?? (topicWeightByHost[host] != nil ? host : nil)
            return (score, name)
        }

        // MARK: Currently-open lookup — tabs viewed recently are neither
        // "forgotten" nor "pick up", they're just what you're already doing.
        var openTabByDedupeKey: [String: SyncedTab] = [:]
        for tab in state.tabs {
            guard let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true else { continue }
            openTabByDedupeKey[EmergingURLUtils.dedupeKey(url)] = tab
        }

        // MARK: Forgotten candidates — old bookmarks, and tabs that have sat
        // unread. A missing/zero timestamp means "no known recent view",
        // which counts as stale rather than fresh — that's the 99-open-tabs
        // case this lane exists for.
        var forgottenCandidates: [EmergingCandidate] = []

        for blob in state.bookmarkBlobs {
            for bm in blob.bookmarks {
                guard let url = URL(string: bm.url), url.scheme?.hasPrefix("http") == true else { continue }
                guard !isSuppressed(url) else { continue }
                let ageDays = bm.dateAdded.map { now.timeIntervalSince($0) / 86400 } ?? Self.forgottenBookmarkAgeDays + 1
                guard ageDays >= Self.forgottenBookmarkAgeDays else { continue }

                let host = url.host()?.lowercased() ?? ""
                let title = bm.title.isEmpty ? (url.host() ?? bm.url) : bm.title
                let (score, topicName) = topicAffinity(host: host, title: title)
                guard score > 0 else { continue }

                let leafFolder = bm.folderPath.flatMap { BookmarkTreeBuilder.splitPath($0).last } ?? blob.browserName
                forgottenCandidates.append(EmergingCandidate(
                    dedupeKey: EmergingURLUtils.dedupeKey(url),
                    title: title,
                    url: url,
                    host: host,
                    ageInDays: ageDays,
                    visitCount: 1,
                    topicScore: score,
                    topicName: topicName,
                    make: {
                        EmergingItem(
                            id: "forgotten_bm_\(bm.id)",
                            title: title,
                            url: url,
                            domain: host,
                            badgeText: leafFolder,
                            reason: topicName.map { "Saved \(formatAge(ageDays)) ago · matches \($0)" }
                                ?? "Saved \(formatAge(ageDays)) ago",
                            source: .bookmark(
                                bookmark: bm,
                                browserName: blob.browserName,
                                profileName: blob.profileName,
                                deviceID: blob.deviceID
                            ),
                            lane: .forgotten
                        )
                    }
                ))
            }
        }

        for tab in state.tabs {
            guard let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true else { continue }
            guard !isSuppressed(url) else { continue }
            let hasKnownTimestamp = tab.timestamp.timeIntervalSince1970 > 0
            let idleDays = hasKnownTimestamp ? now.timeIntervalSince(tab.timestamp) / 86400 : nil
            let isStale = !hasKnownTimestamp || (idleDays ?? 0) >= Self.forgottenTabIdleDays
            guard isStale else { continue }
            guard !tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let host = url.host()?.lowercased() ?? ""
            let (score, topicName) = topicAffinity(host: host, title: tab.title)
            guard score > 0 else { continue }

            forgottenCandidates.append(EmergingCandidate(
                dedupeKey: EmergingURLUtils.dedupeKey(url),
                title: tab.title,
                url: url,
                host: host,
                ageInDays: idleDays,
                visitCount: 1,
                topicScore: score,
                topicName: topicName,
                make: {
                    let ageText = idleDays.map { "Open \(formatAge($0))" } ?? "Sitting open, unread"
                    return EmergingItem(
                        id: "forgotten_tab_\(tab.id)",
                        title: tab.title,
                        url: url,
                        domain: host,
                        badgeText: "Open tab · \(tab.browserName)",
                        reason: topicName.map { "\(ageText) · matches \($0)" } ?? ageText,
                        source: .tab(tab: tab),
                        lane: .forgotten
                    )
                }
            ))
        }

        // MARK: Pick up candidates — pages visited in the last few days that
        // aren't already sitting open in front of you. Repeat visits (e.g.
        // the same article read across several history hits, once dedupe
        // strips tracking query strings) raise the score.
        var pickUpByKey: [String: (title: String, url: URL, host: String, mostRecent: Date, visitCount: Int)] = [:]

        for slice in state.historySlices {
            for entry in slice.entries {
                let ageDays = now.timeIntervalSince(entry.lastVisitedAt) / 86400
                guard ageDays <= Self.pickUpRecentDays else { continue }
                guard let url = URL(string: entry.url), url.scheme?.hasPrefix("http") == true else { continue }
                guard !isSuppressed(url) else { continue }
                let key = EmergingURLUtils.dedupeKey(url)
                guard openTabByDedupeKey[key] == nil else { continue } // already open, not "pick up"

                if var existing = pickUpByKey[key] {
                    existing.visitCount += 1
                    if entry.lastVisitedAt > existing.mostRecent {
                        existing.mostRecent = entry.lastVisitedAt
                    }
                    pickUpByKey[key] = existing
                } else {
                    pickUpByKey[key] = (
                        title: entry.title.isEmpty ? (url.host() ?? entry.url) : entry.title,
                        url: url,
                        host: url.host()?.lowercased() ?? "",
                        mostRecent: entry.lastVisitedAt,
                        visitCount: 1
                    )
                }
            }
        }

        var pickUpCandidates: [EmergingCandidate] = []
        for (key, entry) in pickUpByKey {
            let ageDays = now.timeIntervalSince(entry.mostRecent) / 86400
            let (topicScore, topicName) = topicAffinity(host: entry.host, title: entry.title)
            let recencyScore = max(0, Self.pickUpRecentDays - ageDays)
            let combinedScore = recencyScore * 10 + Double(entry.visitCount) * 3 + topicScore

            pickUpCandidates.append(EmergingCandidate(
                dedupeKey: key,
                title: entry.title,
                url: entry.url,
                host: entry.host,
                ageInDays: ageDays,
                visitCount: entry.visitCount,
                topicScore: combinedScore,
                topicName: topicName,
                make: {
                    let visitText = entry.visitCount > 1 ? "Visited \(entry.visitCount)×" : "Visited \(formatAge(ageDays)) ago"
                    return EmergingItem(
                        id: "pickup_\(key.hashValue)",
                        title: entry.title,
                        url: entry.url,
                        domain: entry.host,
                        badgeText: topicName ?? "Recently visited",
                        reason: topicName.map { "\(visitText) · related to \($0)" } ?? visitText,
                        source: .generic,
                        lane: .pickUp
                    )
                }
            ))
        }

        // MARK: Rank + slot each lane independently, applying topic/host
        // variety caps and the read/tool filter last (cheapest to check
        // first, model check only for whatever's left standing).
        // Forgotten ranks staleness first (oldest, best-matching link wins);
        // Pick up ranks its combined recency/visit/topic score first — its
        // `ageInDays` is always small (≤3), so sorting age-first there would
        // backwards-rank "just visited" below "visited 3 days ago".
        func select(from candidates: [EmergingCandidate], target: Int, ageFirst: Bool) -> [EmergingItem] {
            let ranked = candidates.sorted {
                if ageFirst, $0.ageInDays != $1.ageInDays {
                    return ($0.ageInDays ?? .greatestFiniteMagnitude) > ($1.ageInDays ?? .greatestFiniteMagnitude)
                }
                return $0.topicScore > $1.topicScore
            }
            var picked: [EmergingItem] = []
            var seenKeys = Set<String>()
            var topicCounts: [String: Int] = [:]
            var hostCounts: [String: Int] = [:]

            for candidate in ranked {
                guard picked.count < target else { break }
                guard seenKeys.insert(candidate.dedupeKey).inserted else { continue }
                if let topic = candidate.topicName {
                    let count = topicCounts[topic, default: 0]
                    guard count < Self.maxPerTopic else { continue }
                    topicCounts[topic] = count + 1
                }
                let hostCount = hostCounts[candidate.host, default: 0]
                guard hostCount < Self.maxPerHost else { continue }
                hostCounts[candidate.host] = hostCount + 1
                picked.append(candidate.make())
            }
            return picked
        }

        let forgotten = select(from: forgottenCandidates, target: Self.forgottenTarget, ageFirst: true)
        let pickUp = select(from: pickUpCandidates, target: Self.pickUpTarget, ageFirst: false)

        // Read/tool filter: only drops items the on-device model has
        // already labeled a tool. Unclassified links stay in — classifying
        // happens after this function returns (see `refresh()`), so a link
        // gets one silent chance before the model has an opinion, and drops
        // out on the following refresh if it comes back "tool".
        return (forgotten + pickUp).filter { item in
            classificationCache[EmergingURLUtils.dedupeKey(item.url)] != false
        }
    }

    private nonisolated static func extractTopicKeywords(from text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { word in
                guard word.count >= 4 else { return false }
                guard !commonStopWords.contains(word) else { return false }
                // Drop numeric-ish / id-shaped tokens (dates, hex fragments,
                // UUID chunks) — they're never a real topic.
                let digitCount = word.filter(\.isNumber).count
                if digitCount * 2 >= word.count { return false }
                return true
            }
        return Set(words)
    }

    nonisolated private static func formatAge(_ days: Double) -> String {
        if days < 1 { return "today" }
        if days < 2 { return "1 day" }
        if days < 30 { return "\(Int(days)) days" }
        if days < 60 { return "1 month" }
        return "\(Int(days / 30)) months"
    }

    nonisolated private static let commonStopWords: Set<String> = [
        "this", "that", "with", "from", "your", "what", "where", "when", "about",
        "https", "http", "www", "html", "com", "page", "home", "index", "github",
        "google", "apple", "login", "view", "edit", "share", "post", "there",
        "here", "just", "into", "over", "than", "then", "them", "they", "will",
        "have", "been", "were", "does", "each", "more", "most", "some", "such",
        "only", "other", "which", "their", "these", "those", "would", "could",
        "should", "search", "results", "inbox", "chat", "sign", "signin", "signup",
        "dashboard", "account", "settings", "profile", "welcome", "loading"
    ]
}
