import Foundation
import SwiftUI
import Combine
import FastTabSync

public enum EmergingItemSource: Hashable, Sendable {
    case bookmark(bookmark: SyncedBookmarkItem, browserName: String, profileName: String?, deviceID: String)
    case tab(tab: SyncedTab)
    case generic
}

public struct EmergingItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let domain: String
    public let badgeText: String
    public let reason: String?
    public let source: EmergingItemSource

    public init(
        id: String,
        title: String,
        url: URL,
        domain: String,
        badgeText: String,
        reason: String? = nil,
        source: EmergingItemSource = .generic
    ) {
        self.id = id
        self.title = title.isEmpty ? domain : title
        self.url = url
        self.domain = domain
        self.badgeText = badgeText
        self.reason = reason
        self.source = source
    }
}

@MainActor
public final class EmergingContentProvider: ObservableObject {
    public static let shared = EmergingContentProvider()

    @Published public private(set) var items: [EmergingItem] = []
    @Published public private(set) var isProcessing: Bool = false

    public func removeItem(id: String) {
        items.removeAll { $0.id == id }
    }

    private static let targetCount = 10
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
        let intelligenceClusters = IntelligenceService.shared.topicClusters

        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let computed = Self.computeRecommendations(
                state: state,
                lastOpened: lastOpened,
                intelligenceClusters: intelligenceClusters
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.items = computed
                self?.isProcessing = false
            }
        }
    }

    private nonisolated static func computeRecommendations(
        state: CachedSyncState,
        lastOpened: [LastOpenedItem],
        intelligenceClusters: [TopicCluster]
    ) -> [EmergingItem] {
        var recommendations: [EmergingItem] = []
        var seenNormalizedURLs = Set<String>()

        // Exclude items already recently opened on iPhone
        for opened in lastOpened.prefix(15) {
            if let u = URL(string: opened.url) {
                seenNormalizedURLs.insert(normalize(u))
            }
        }

        // 1. Gather Seeds: domains and keywords from iPhone reading and Mac open tabs
        var seedHosts = Set<String>()
        var seedKeywords = Set<String>()

        for opened in lastOpened.prefix(10) {
            if !opened.domain.isEmpty { seedHosts.insert(opened.domain.lowercased()) }
            seedKeywords.formUnion(extractFastKeywords(from: opened.title))
        }

        for tab in state.tabs.prefix(15) {
            if let host = URL(string: tab.url)?.host() { seedHosts.insert(host.lowercased()) }
            seedKeywords.formUnion(extractFastKeywords(from: tab.title))
        }

        let liveBookmarkIDs = Set(state.bookmarkBlobs.flatMap { $0.bookmarks.map(\.id) })

        // 2. Extract from Intelligence Service Topic Clusters (Semantic matches from Mac)
        for cluster in intelligenceClusters {
            for browsingItem in cluster.recentItems {
                guard let url = URL(string: browsingItem.url), url.scheme?.hasPrefix("http") == true else { continue }
                let norm = normalize(url)
                if seenNormalizedURLs.insert(norm).inserted {
                    recommendations.append(EmergingItem(
                        id: "intel_item_\(browsingItem.id)",
                        title: browsingItem.displayTitle,
                        url: url,
                        domain: browsingItem.host,
                        badgeText: cluster.name,
                        reason: "Related to \(cluster.name)"
                    ))
                }
                if recommendations.count >= 6 { break }
            }

            for bm in cluster.relatedBookmarks {
                guard liveBookmarkIDs.contains(bm.id) else { continue }
                guard let url = URL(string: bm.url), url.scheme?.hasPrefix("http") == true else { continue }
                let norm = normalize(url)
                if seenNormalizedURLs.insert(norm).inserted {
                    let bookmarkItem = SyncedBookmarkItem(
                        id: bm.id,
                        title: bm.title,
                        url: bm.url,
                        folderPath: bm.folderPath,
                        dateAdded: nil
                    )
                    recommendations.append(EmergingItem(
                        id: "intel_bm_\(bm.id)",
                        title: bm.displayTitle,
                        url: url,
                        domain: url.host() ?? "",
                        badgeText: bm.folderDisplayName,
                        reason: "From bookmarks · \(cluster.name)",
                        source: .bookmark(
                            bookmark: bookmarkItem,
                            browserName: bm.browserName,
                            profileName: bm.profileName.isEmpty ? nil : bm.profileName,
                            deviceID: bm.deviceID
                        )
                    ))
                }
                if recommendations.count >= 8 { break }
            }
        }

        // 3. Match against Bookmarks with Host or Keyword Affinity
        if recommendations.count < targetCount {
            for blob in state.bookmarkBlobs {
                for bm in blob.bookmarks {
                    guard let url = URL(string: bm.url), url.scheme?.hasPrefix("http") == true else { continue }
                    let norm = normalize(url)
                    if seenNormalizedURLs.contains(norm) { continue }

                    let host = url.host()?.lowercased() ?? ""
                    let bmKeywords = extractFastKeywords(from: bm.title)

                    var isMatch = false
                    var matchedReason: String? = nil

                    if !host.isEmpty && seedHosts.contains(host) {
                        isMatch = true
                        matchedReason = "Similar to pages you read on \(host)"
                    } else if !seedKeywords.intersection(bmKeywords).isEmpty {
                        isMatch = true
                        let common = seedKeywords.intersection(bmKeywords).first?.capitalized ?? "Reading"
                        matchedReason = "Related to \(common)"
                    }

                    if isMatch && seenNormalizedURLs.insert(norm).inserted {
                        let leafFolder = bm.folderPath.flatMap { BookmarkTreeBuilder.splitPath($0).last } ?? blob.browserName
                        recommendations.append(EmergingItem(
                            id: "bm_affinity_\(bm.id)",
                            title: bm.title.isEmpty ? (url.host() ?? bm.url) : bm.title,
                            url: url,
                            domain: host,
                            badgeText: leafFolder,
                            reason: matchedReason,
                            source: .bookmark(
                                bookmark: bm,
                                browserName: blob.browserName,
                                profileName: blob.profileName,
                                deviceID: blob.deviceID
                            )
                        ))
                    }

                    if recommendations.count >= targetCount { break }
                }
                if recommendations.count >= targetCount { break }
            }
        }

        // 4. Graceful Fallback: Random/Curated Picks from Bookmarks & Open Tabs
        if recommendations.count < targetCount {
            var fallbackPool: [EmergingItem] = []

            for blob in state.bookmarkBlobs {
                for bm in blob.bookmarks {
                    guard let url = URL(string: bm.url), url.scheme?.hasPrefix("http") == true else { continue }
                    let norm = normalize(url)
                    if seenNormalizedURLs.contains(norm) { continue }

                    let leafFolder = bm.folderPath.flatMap { BookmarkTreeBuilder.splitPath($0).last } ?? blob.browserName
                    fallbackPool.append(EmergingItem(
                        id: "fallback_bm_\(bm.id)",
                        title: bm.title.isEmpty ? (url.host() ?? bm.url) : bm.title,
                        url: url,
                        domain: url.host() ?? "",
                        badgeText: leafFolder,
                        reason: "From your bookmarks",
                        source: .bookmark(
                            bookmark: bm,
                            browserName: blob.browserName,
                            profileName: blob.profileName,
                            deviceID: blob.deviceID
                        )
                    ))
                }
            }

            for tab in state.tabs {
                guard let url = URL(string: tab.url), url.scheme?.hasPrefix("http") == true else { continue }
                let norm = normalize(url)
                if seenNormalizedURLs.contains(norm) { continue }

                fallbackPool.append(EmergingItem(
                    id: "fallback_tab_\(tab.id)",
                    title: tab.title.isEmpty ? (url.host() ?? tab.url) : tab.title,
                    url: url,
                    domain: url.host() ?? "",
                    badgeText: "Open tab · \(tab.browserName)",
                    reason: "Open on Mac",
                    source: .tab(tab: tab)
                ))
            }

            fallbackPool.shuffle()
            for item in fallbackPool {
                let norm = normalize(item.url)
                if seenNormalizedURLs.insert(norm).inserted {
                    recommendations.append(item)
                }
                if recommendations.count >= targetCount { break }
            }
        }

        return recommendations
    }

    private nonisolated static func normalize(_ url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = (url.query() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "\(host)/\(path)".lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return "\(host)/\(path)?\(query)".lowercased()
        }
    }

    private nonisolated static func extractFastKeywords(from text: String) -> Set<String> {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !commonStopWords.contains($0) }
        return Set(words)
    }

    private static let commonStopWords: Set<String> = [
        "this", "that", "with", "from", "your", "what", "where", "when", "about",
        "https", "http", "www", "html", "com", "page", "home", "index", "github",
        "google", "apple", "login", "view", "edit", "share", "post"
    ]
}
