import Foundation
import SwiftUI
import NaturalLanguage
import OSLog
import FastTabSync
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Models

public enum BrowsingItemSource: Hashable, Sendable {
    case openTab(deviceID: String, browserName: String, tabID: Int?)
    case history(deviceID: String, browserName: String)

    public var badgeLabel: String {
        switch self {
        case .openTab(_, let browser, _):
            return "Open tab · \(browser)"
        case .history(_, let browser):
            return "History · \(browser)"
        }
    }

    public var isTab: Bool {
        if case .openTab = self { return true }
        return false
    }
}

public struct BrowsingItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let source: BrowsingItemSource
    public let timestamp: Date

    public init(id: String, title: String, url: String, source: BrowsingItemSource, timestamp: Date) {
        self.id = id
        self.title = title
        self.url = url
        self.source = source
        self.timestamp = timestamp
    }

    public var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return URL(string: url)?.host() ?? url
    }

    public var host: String {
        URL(string: url)?.host() ?? ""
    }
}

public struct BookmarkMatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let folderPath: String?
    public let browserName: String
    public let profileName: String
    public let deviceID: String

    public var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return URL(string: url)?.host() ?? url
    }

    public var folderDisplayName: String {
        guard let folderPath, !folderPath.isEmpty else { return "Top Level" }
        return folderPath
    }
}

public struct TopicCluster: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let summary: String?
    public let recentItems: [BrowsingItem]
    public let relatedBookmarks: [BookmarkMatch]
    public let suggestedFolderName: String

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String? = nil,
        recentItems: [BrowsingItem],
        relatedBookmarks: [BookmarkMatch],
        suggestedFolderName: String
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.recentItems = recentItems
        self.relatedBookmarks = relatedBookmarks
        self.suggestedFolderName = suggestedFolderName
    }
}

public struct BookmarkFolderInfo: Hashable, Sendable {
    public let deviceID: String
    public let browserName: String
    public let profileName: String
    public let folderPath: [String]
    public let displayName: String
    public let sampleBookmarkTitles: [String]

    public init(
        deviceID: String,
        browserName: String,
        profileName: String,
        folderPath: [String],
        displayName: String,
        sampleBookmarkTitles: [String]
    ) {
        self.deviceID = deviceID
        self.browserName = browserName
        self.profileName = profileName
        self.folderPath = folderPath
        self.displayName = displayName
        self.sampleBookmarkTitles = sampleBookmarkTitles
    }
}

public struct FolderSuggestion: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let tab: SyncedTab
    public let suggestedFolder: BookmarkFolderInfo
    public let confidence: Double
    public let reason: String

    public init(
        id: UUID = UUID(),
        tab: SyncedTab,
        suggestedFolder: BookmarkFolderInfo,
        confidence: Double,
        reason: String
    ) {
        self.id = id
        self.tab = tab
        self.suggestedFolder = suggestedFolder
        self.confidence = confidence
        self.reason = reason
    }
}

// MARK: - Intelligence Service

@MainActor
public final class IntelligenceService: ObservableObject {
    public static let shared = IntelligenceService()

    @Published public private(set) var topicClusters: [TopicCluster] = []
    @Published public private(set) var folderSuggestions: [FolderSuggestion] = []
    @Published public private(set) var userInterests: [String] = []
    @Published public private(set) var isProcessing: Bool = false
    @Published public private(set) var lastProcessedAt: Date?
    @Published public private(set) var lastErrorMessage: String?

    private let logger = Logger(subsystem: "app.theindie.FastTab", category: "IntelligenceService")
    private var activeTask: Task<Void, Never>?
    private var dismissedSuggestionIDs: Set<UUID> = []

    private init() {
        restoreFromCache()
    }

    // MARK: - Public Actions

    /// Triggers a full recompute of emerging topics and bookmark suggestions.
    public func analyze(force: Bool = false) {
        activeTask?.cancel()
        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runAnalysis(force: force)
        }
    }

    public func dismissSuggestion(id: UUID) {
        dismissedSuggestionIDs.insert(id)
        folderSuggestions.removeAll { $0.id == id }
    }

    /// Saves all items in a topic cluster into a designated bookmark folder on the active/target device.
    public func saveClusterToFolder(
        cluster: TopicCluster,
        folderPath: [String],
        targetDeviceID: String,
        browserName: String,
        profileName: String
    ) {
        let consumer = SyncConsumer.shared
        for item in cluster.recentItems {
            consumer.sendAddBookmark(
                title: item.displayTitle,
                url: item.url,
                destinationBrowserName: browserName,
                destinationProfileName: profileName,
                destinationFolderPath: folderPath,
                targetDeviceID: targetDeviceID
            )
        }
    }

    /// Saves a single suggested tab into its target bookmark folder.
    public func acceptSuggestion(_ suggestion: FolderSuggestion) {
        let folder = suggestion.suggestedFolder
        let targetDeviceID = folder.deviceID.isEmpty ? suggestion.tab.deviceID : folder.deviceID
        SyncConsumer.shared.sendAddBookmark(
            title: suggestion.tab.title.isEmpty ? suggestion.tab.url : suggestion.tab.title,
            url: suggestion.tab.url,
            destinationBrowserName: folder.browserName,
            destinationProfileName: folder.profileName,
            destinationFolderPath: folder.folderPath,
            targetDeviceID: targetDeviceID
        )
        dismissSuggestion(id: suggestion.id)
    }

    // MARK: - Cache & State Restoration

    private func restoreFromCache() {
        let cached = IntelligenceCache.shared.state
        self.userInterests = cached.interestProfile
        self.lastProcessedAt = cached.computedAt

        // Hydrate items from LocalCache
        let localState = LocalCache.shared.state
        let browsingMap = collectAllBrowsingItems(state: localState)
        let bookmarkMap = collectAllBookmarkMatches(state: localState)
        let folderMap = collectAllFolderInfos(state: localState)

        self.topicClusters = cached.topicClusters.compactMap { cluster in
            let items = cluster.recentItemIDs.compactMap { browsingMap[$0] }
            if items.isEmpty { return nil }
            let bms = cluster.relatedBookmarkIDs.compactMap { bookmarkMap[$0] }
            return TopicCluster(
                id: cluster.id,
                name: cluster.name,
                summary: cluster.summary,
                recentItems: items,
                relatedBookmarks: bms,
                suggestedFolderName: cluster.suggestedFolderName
            )
        }

        let tabsByID = Dictionary(localState.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.folderSuggestions = cached.folderSuggestions.compactMap { sug in
            guard let tab = tabsByID[sug.tabID] else { return nil }
            let folderKey = "\(sug.targetDeviceID)|\(sug.targetBrowserName)|\(sug.targetProfileName)|\(sug.folderPath.joined(separator: "/"))"
            let fallbackKey = "\(sug.targetBrowserName)|\(sug.targetProfileName)|\(sug.folderPath.joined(separator: "/"))"
            guard let folderInfo = folderMap[folderKey] ?? folderMap[fallbackKey] else { return nil }
            return FolderSuggestion(
                id: sug.id,
                tab: tab,
                suggestedFolder: folderInfo,
                confidence: sug.confidence,
                reason: sug.reason
            )
        }
    }

    // MARK: - Core Analysis Pipeline

    private func runAnalysis(force: Bool) async {
        isProcessing = true
        lastErrorMessage = nil
        defer { isProcessing = false }

        let localState = LocalCache.shared.state
        let currentFingerprint = computeDataFingerprint(state: localState)

        if !force,
           let cachedTime = lastProcessedAt,
           Date().timeIntervalSince(cachedTime) < 300,
           IntelligenceCache.shared.state.dataFingerprint == currentFingerprint,
           !topicClusters.isEmpty {
            logger.info("Intelligence cache is still fresh and data unchanged. Skipping computation.")
            return
        }

        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recentItems = collectRecentBrowsingItems(state: localState, cutoffDate: sevenDaysAgo)
        let allBookmarks = collectAllBookmarksList(state: localState)
        let availableFolders = Array(collectAllFolderInfos(state: localState).values)

        guard !recentItems.isEmpty || !localState.tabs.isEmpty else {
            self.topicClusters = []
            self.folderSuggestions = []
            return
        }

        // 1. Build / Refresh User Interest Profile
        let profile = await buildOrRefreshUserProfile(
            bookmarks: allBookmarks,
            history: recentItems,
            cachedProfile: IntelligenceCache.shared.state.interestProfile,
            lastRebuilt: IntelligenceCache.shared.state.lastProfileRebuiltAt
        )
        self.userInterests = profile

        // 2. Cluster Recent Activity into Topics (Emerging)
        let clusters = await clusterIntoTopics(
            items: recentItems,
            bookmarks: allBookmarks,
            userInterests: profile
        )
        if Task.isCancelled { return }
        self.topicClusters = clusters

        // 3. Generate Smart Bookmark Suggestions
        let suggestions = await generateFolderSuggestions(
            openTabs: localState.tabs,
            availableFolders: availableFolders,
            bookmarks: allBookmarks
        )
        if Task.isCancelled { return }
        self.folderSuggestions = suggestions.filter { !self.dismissedSuggestionIDs.contains($0.id) }

        self.lastProcessedAt = Date()

        // 4. Save to Disk Cache
        let cachedClusters = clusters.map { c in
            CachedTopicCluster(
                id: c.id,
                name: c.name,
                summary: c.summary,
                recentItemIDs: c.recentItems.map(\.id),
                relatedBookmarkIDs: c.relatedBookmarks.map(\.id),
                suggestedFolderName: c.suggestedFolderName
            )
        }
        let cachedSuggestions = self.folderSuggestions.map { s in
            CachedFolderSuggestion(
                id: s.id,
                tabID: s.tab.id,
                targetDeviceID: s.suggestedFolder.deviceID,
                targetBrowserName: s.suggestedFolder.browserName,
                targetProfileName: s.suggestedFolder.profileName,
                folderPath: s.suggestedFolder.folderPath,
                confidence: s.confidence,
                reason: s.reason
            )
        }
        let cachedState = CachedIntelligenceState(
            interestProfile: profile,
            lastProfileRebuiltAt: Date(),
            topicClusters: cachedClusters,
            folderSuggestions: cachedSuggestions,
            computedAt: Date(),
            dataFingerprint: currentFingerprint
        )
        IntelligenceCache.shared.updateState(cachedState)
    }

    // MARK: - User Interest Profile

    private func buildOrRefreshUserProfile(
        bookmarks: [BookmarkMatch],
        history: [BrowsingItem],
        cachedProfile: [String],
        lastRebuilt: Date?
    ) async -> [String] {
        if let lastRebuilt, Date().timeIntervalSince(lastRebuilt) < 86400, !cachedProfile.isEmpty {
            return cachedProfile
        }

        // Collect distinct folder names and frequent title keywords
        var folderNames = Set<String>()
        for bm in bookmarks {
            if let path = bm.folderPath, !path.isEmpty {
                let parts = BookmarkTreeBuilder.splitPath(path)
                for part in parts where !part.isEmpty && part != "Bookmark Bar" && part != "Other Bookmarks" {
                    folderNames.insert(part)
                }
            }
        }

        let textCorpus = (bookmarks.map(\.title) + history.map(\.title)).joined(separator: " ")
        let topKeywords = extractTopKeywords(from: textCorpus, count: 12)
        var combined = Array(folderNames) + topKeywords
        combined = Array(Set(combined)).filter { $0.count >= 3 }.prefix(15).map { $0 }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let prompt = """
                Based on these bookmark folders and browsing keywords: \(combined.joined(separator: ", ")), list 6-10 concise high-level user interest topic labels (e.g. "Swift & iOS Development", "AI & Machine Learning", "Design Tools", "Financial News"). Return comma separated list only.
                """
                let session = LanguageModelSession(model: .default)
                let response = try await session.respond(to: prompt)
                let parsed = response.content
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !parsed.isEmpty {
                    return parsed
                }
            } catch {
                logger.warning("LLM profile synthesis failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif

        return combined
    }

    // MARK: - Topic Clustering

    private func clusterIntoTopics(
        items: [BrowsingItem],
        bookmarks: [BookmarkMatch],
        userInterests: [String]
    ) async -> [TopicCluster] {
        guard !items.isEmpty else { return [] }

        // Deduplicate items with the same URL
        var uniqueItems: [BrowsingItem] = []
        var seenURLs = Set<String>()
        for item in items {
            let normalized = normalizeURL(item.url)
            if !seenURLs.contains(normalized) {
                seenURLs.insert(normalized)
                uniqueItems.append(item)
            }
        }

        // Semantic & Domain Grouping
        var groups: [[BrowsingItem]] = []
        var assignedIndices = Set<Int>()

        let embedding = NLEmbedding.wordEmbedding(for: .english)
        // Pre-extract keywords once for each unique item to avoid O(N^2) NLTagger calls
        let itemKeywords = uniqueItems.map { extractKeywords(from: $0.displayTitle) }

        for i in 0..<uniqueItems.count {
            if assignedIndices.contains(i) { continue }
            var currentGroup = [uniqueItems[i]]
            assignedIndices.insert(i)

            let itemA = uniqueItems[i]
            let wordsA = itemKeywords[i]

            for j in (i + 1)..<uniqueItems.count {
                if assignedIndices.contains(j) { continue }
                let itemB = uniqueItems[j]

                var isSimilar = false

                // Direct host match
                if !itemA.host.isEmpty && itemA.host == itemB.host {
                    isSimilar = true
                }

                // Word overlap
                let wordsB = itemKeywords[j]
                let commonWords = wordsA.intersection(wordsB)
                if !commonWords.isEmpty && (commonWords.count >= 2 || wordsA.count <= 2 || wordsB.count <= 2) {
                    isSimilar = true
                }

                // NL Embedding vector similarity
                if !isSimilar, let emb = embedding {
                    var maxSim: Double = 0.0
                    for wa in wordsA {
                        for wb in wordsB {
                            let sim = emb.distance(between: wa.lowercased(), and: wb.lowercased())
                            // Distance is [0, 2]; closer to 0 is more similar
                            if sim < 0.75 {
                                maxSim = max(maxSim, 1.0 - (sim / 2.0))
                            }
                        }
                    }
                    if maxSim >= 0.65 {
                        isSimilar = true
                    }
                }

                if isSimilar {
                    currentGroup.append(itemB)
                    assignedIndices.insert(j)
                }
            }
            groups.append(currentGroup)
        }

        // Merge very small 1-item groups if they have domain or keyword affinity
        var mergedGroups = groups.sorted { $0.count > $1.count }
        if mergedGroups.count > 12 {
            mergedGroups = Array(mergedGroups.prefix(12))
        }

        // Generate names, summaries, and match related bookmarks for each group
        var clusters: [TopicCluster] = []
        for group in mergedGroups {
            let titles = group.map(\.displayTitle)
            let clusterName = await nameCluster(titles: titles, userInterests: userInterests, sampleHost: group.first?.host ?? "")
            let relatedBMs = findRelatedBookmarks(for: group, allBookmarks: bookmarks)

            let cluster = TopicCluster(
                name: clusterName,
                summary: "\(group.count) recent pages · \(relatedBMs.count) related bookmarks",
                recentItems: group.sorted { $0.timestamp > $1.timestamp },
                relatedBookmarks: relatedBMs,
                suggestedFolderName: clusterName
            )
            clusters.append(cluster)
        }

        return clusters
    }

    private func nameCluster(titles: [String], userInterests: [String], sampleHost: String) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let prompt = """
                Generate a concise 2-4 word topic title (e.g. "SwiftUI Architecture", "Machine Learning Research", "Tech News") for this cluster of web pages:
                \(titles.prefix(5).joined(separator: "\n"))
                Existing user interest categories: \(userInterests.prefix(6).joined(separator: ", ")).
                If one of the user interest categories matches closely, use or adapt it. Otherwise create an accurate title. Respond with title ONLY.
                """
                let session = LanguageModelSession(model: .default)
                let response = try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                if !text.isEmpty && text.count <= 45 {
                    return text
                }
            } catch {
                logger.warning("LLM cluster naming failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif

        // Heuristic naming fallback
        let topWords = extractTopKeywords(from: titles.joined(separator: " "), count: 2)
        if !topWords.isEmpty {
            return topWords.map(\.capitalized).joined(separator: " ")
        }
        if !sampleHost.isEmpty {
            let cleanHost = sampleHost.replacingOccurrences(of: "www.", with: "")
            return cleanHost.capitalized
        }
        return "Emerging Topic"
    }

    private func findRelatedBookmarks(for group: [BrowsingItem], allBookmarks: [BookmarkMatch]) -> [BookmarkMatch] {
        let groupHosts = Set(group.map(\.host).filter { !$0.isEmpty })
        let groupKeywords = Set(group.flatMap { extractKeywords(from: $0.displayTitle) })

        var matches: [BookmarkMatch] = []
        var seenURLs = Set<String>()

        for bm in allBookmarks {
            let normalized = normalizeURL(bm.url)
            if seenURLs.contains(normalized) { continue }

            let bmHost = URL(string: bm.url)?.host() ?? ""
            let bmKeywords = extractKeywords(from: bm.displayTitle)

            var score = 0
            if !bmHost.isEmpty && groupHosts.contains(bmHost) {
                score += 3
            }
            let overlap = groupKeywords.intersection(bmKeywords)
            score += overlap.count * 2

            if score >= 3 {
                seenURLs.insert(normalized)
                matches.append(bm)
            }
            if matches.count >= 6 { break }
        }

        return matches
    }

    // MARK: - Bookmark Folder Suggestions

    private func generateFolderSuggestions(
        openTabs: [SyncedTab],
        availableFolders: [BookmarkFolderInfo],
        bookmarks: [BookmarkMatch]
    ) async -> [FolderSuggestion] {
        guard !openTabs.isEmpty && !availableFolders.isEmpty else { return [] }

        var suggestions: [FolderSuggestion] = []

        for tab in openTabs {
            let tabTitle = tab.title.isEmpty ? tab.url : tab.title
            let tabHost = URL(string: tab.url)?.host() ?? ""
            let tabKeywords = extractKeywords(from: tabTitle)

            var bestFolder: BookmarkFolderInfo?
            var bestScore: Double = 0.0
            var matchedKeywords: [String] = []

            for folder in availableFolders {
                var folderScore: Double = 0.0
                var currentMatches: [String] = []

                let folderNameKeywords = extractKeywords(from: folder.displayName)
                let nameOverlap = tabKeywords.intersection(folderNameKeywords)
                if !nameOverlap.isEmpty {
                    folderScore += Double(nameOverlap.count) * 2.5
                    currentMatches.append(contentsOf: nameOverlap)
                }

                // Sample bookmark overlap
                for sample in folder.sampleBookmarkTitles {
                    let sampleKeywords = extractKeywords(from: sample)
                    let overlap = tabKeywords.intersection(sampleKeywords)
                    if !overlap.isEmpty {
                        folderScore += Double(overlap.count) * 1.5
                        currentMatches.append(contentsOf: overlap)
                    }
                    if !tabHost.isEmpty && sample.localizedCaseInsensitiveContains(tabHost) {
                        folderScore += 2.0
                    }
                }

                if folderScore > bestScore {
                    bestScore = folderScore
                    bestFolder = folder
                    matchedKeywords = currentMatches
                }
            }

            if let folder = bestFolder, bestScore >= 2.0 {
                let confidence = min(1.0, bestScore / 8.0)
                let reason = await explainSuggestion(
                    tabTitle: tabTitle,
                    folderName: folder.displayName,
                    matchedKeywords: Array(Set(matchedKeywords)),
                    sampleCount: folder.sampleBookmarkTitles.count
                )
                suggestions.append(FolderSuggestion(
                    tab: tab,
                    suggestedFolder: folder,
                    confidence: confidence,
                    reason: reason
                ))
            }
        }

        return suggestions.sorted { $0.confidence > $1.confidence }
    }

    private func explainSuggestion(
        tabTitle: String,
        folderName: String,
        matchedKeywords: [String],
        sampleCount: Int
    ) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let prompt = """
                Write a 1-sentence reason (max 12 words) why tab "\(tabTitle)" belongs in bookmark folder "\(folderName)". Related topics: \(matchedKeywords.joined(separator: ", ")).
                """
                let session = LanguageModelSession(model: .default)
                let response = try await session.respond(to: prompt)
                let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
                if !cleaned.isEmpty {
                    return cleaned
                }
            } catch {
                // Fall back
            }
        }
        #endif

        if !matchedKeywords.isEmpty {
            return "Matches topics: \(matchedKeywords.prefix(3).joined(separator: ", "))"
        }
        return "Similar to \(sampleCount) other bookmarks in \(folderName)"
    }

    // MARK: - Data Collection Helpers

    private func collectRecentBrowsingItems(state: CachedSyncState, cutoffDate: Date) -> [BrowsingItem] {
        var items: [BrowsingItem] = []

        // Open Tabs
        for tab in state.tabs {
            items.append(BrowsingItem(
                id: "tab|\(tab.id)",
                title: tab.title,
                url: tab.url,
                source: .openTab(deviceID: tab.deviceID, browserName: tab.browserName, tabID: tab.tabID),
                timestamp: tab.timestamp
            ))
        }

        // History slices (last 7 days)
        for slice in state.historySlices {
            for entry in slice.entries where entry.lastVisitedAt >= cutoffDate {
                items.append(BrowsingItem(
                    id: "hist|\(entry.id)|\(slice.deviceID)",
                    title: entry.title,
                    url: entry.url,
                    source: .history(deviceID: slice.deviceID, browserName: slice.browserName),
                    timestamp: entry.lastVisitedAt
                ))
            }
        }

        return items
    }

    private func collectAllBookmarksList(state: CachedSyncState) -> [BookmarkMatch] {
        var matches: [BookmarkMatch] = []
        for blob in state.bookmarkBlobs {
            for bm in blob.bookmarks {
                let compoundID = "\(blob.deviceID)|\(blob.browserName)|\(blob.profileName)|\(bm.id)"
                matches.append(BookmarkMatch(
                    id: compoundID,
                    title: bm.title,
                    url: bm.url,
                    folderPath: bm.folderPath,
                    browserName: blob.browserName,
                    profileName: blob.profileName,
                    deviceID: blob.deviceID
                ))
            }
        }
        return matches
    }

    private func collectAllBrowsingItems(state: CachedSyncState) -> [String: BrowsingItem] {
        let items = collectRecentBrowsingItems(state: state, cutoffDate: .distantPast)
        return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func collectAllBookmarkMatches(state: CachedSyncState) -> [String: BookmarkMatch] {
        let list = collectAllBookmarksList(state: state)
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func collectAllFolderInfos(state: CachedSyncState) -> [String: BookmarkFolderInfo] {
        var folders: [String: BookmarkFolderInfo] = [:]
        for blob in state.bookmarkBlobs {
            var bookmarksByPath: [String: [String]] = [:]
            for bm in blob.bookmarks {
                let path = bm.folderPath ?? ""
                bookmarksByPath[path, default: []].append(bm.title)
            }
            for (path, titles) in bookmarksByPath {
                let split = BookmarkTreeBuilder.splitPath(path)
                let displayName = split.isEmpty ? "Top Level" : split.joined(separator: " / ")
                let key = "\(blob.deviceID)|\(blob.browserName)|\(blob.profileName)|\(split.joined(separator: "/"))"
                let fallbackKey = "\(blob.browserName)|\(blob.profileName)|\(split.joined(separator: "/"))"
                let folderInfo = BookmarkFolderInfo(
                    deviceID: blob.deviceID,
                    browserName: blob.browserName,
                    profileName: blob.profileName,
                    folderPath: split,
                    displayName: displayName,
                    sampleBookmarkTitles: Array(titles.prefix(5))
                )
                folders[key] = folderInfo
                if folders[fallbackKey] == nil {
                    folders[fallbackKey] = folderInfo
                }
            }
        }
        return folders
    }

    private func computeDataFingerprint(state: CachedSyncState) -> String {
        let tabCount = state.tabs.count
        let histCount = state.historySlices.reduce(0) { $0 + $1.entries.count }
        let bmCount = state.bookmarkBlobs.reduce(0) { $0 + $1.bookmarks.count }
        return "\(tabCount)_\(histCount)_\(bmCount)"
    }

    private func normalizeURL(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return raw.lowercased() }
        let host = url.host() ?? ""
        let path = url.path()
        return "\(host)\(path)".lowercased()
    }

    private func extractKeywords(from text: String) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text
        var keywords = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .tokenType) { _, range in
            let word = String(text[range]).trimmingCharacters(in: .punctuationCharacters).lowercased()
            if word.count >= 3 && !Self.commonStopWords.contains(word) {
                keywords.insert(word)
            }
            return true
        }
        return keywords
    }

    private func extractTopKeywords(from text: String, count: Int) -> [String] {
        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text
        var frequencies: [String: Int] = [:]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .tokenType) { _, range in
            let word = String(text[range]).trimmingCharacters(in: .punctuationCharacters).lowercased()
            if word.count >= 3 && !Self.commonStopWords.contains(word) {
                frequencies[word, default: 0] += 1
            }
            return true
        }
        return frequencies.sorted { $0.value > $1.value }.prefix(count).map(\.key)
    }

    private static let commonStopWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "your", "what", "when",
        "where", "how", "why", "are", "can", "you", "all", "any", "not", "new",
        "home", "page", "web", "site", "view", "edit", "app", "http", "https", "com", "org", "net"
    ]
}
