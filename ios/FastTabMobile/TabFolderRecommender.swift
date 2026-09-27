import Foundation
import NaturalLanguage
import OSLog
import FastTabSync
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Lazily recommends an existing bookmark folder for each open tab, cached per
/// URL. Rows call `requestIfNeeded`; results publish asynchronously so the tab
/// list never waits. Only recommendations at >= 80% confidence are exposed.
@MainActor
final class TabFolderRecommender: ObservableObject {
    static let shared = TabFolderRecommender()

    /// URL -> result; `.some(nil)` means "computed, nothing confident enough".
    @Published private(set) var resultsByURL: [String: TabFolderRecommendation?] = [:]
    private var inFlightURLs = Set<String>()
    private var lastQueuedTask: Task<Void, Never>?
    private let titleMatcher = TitleSimilarityMatcher()
    private let logger = Logger(subsystem: "app.theindie.FastTabMobile", category: "TabFolderRecommender")

    func recommendation(for tab: SyncedTab) -> TabFolderRecommendation? {
        resultsByURL[tab.url] ?? nil
    }

    /// Hides the chip once the tab has been bookmarked.
    func markBookmarked(_ tab: SyncedTab) {
        resultsByURL[tab.url] = .some(nil)
    }

    func requestIfNeeded(for tab: SyncedTab, state: CachedSyncState) {
        guard resultsByURL[tab.url] == nil, !inFlightURLs.contains(tab.url) else { return }
        guard TabBookmarkEligibility.isReadLaterContent(urlString: tab.url) else {
            resultsByURL[tab.url] = .some(nil)
            return
        }
        inFlightURLs.insert(tab.url)
        let bookmarks = Self.bookmarks(onDevice: tab.deviceID, state: state)
        let previousTask = lastQueuedTask
        // Serialized: one tab scored at a time keeps embedding/model load low.
        lastQueuedTask = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            let result = await self.score(tab: tab, bookmarks: bookmarks)
            self.inFlightURLs.remove(tab.url)
            self.resultsByURL[tab.url] = .some(result.flatMap {
                $0.confidence >= TabFolderVoteScorer.minimumConfidence ? $0 : nil
            })
        }
    }

    private func score(tab: SyncedTab, bookmarks: [ScoredBookmark]) async -> TabFolderRecommendation? {
        guard !bookmarks.isEmpty,
              !TabFolderVoteScorer.isAlreadyBookmarked(tabURL: tab.url, bookmarks: bookmarks) else { return nil }
        let matcher = titleMatcher
        let voted = await Task.detached(priority: .utility) {
            TabFolderVoteScorer.recommend(
                tabURL: tab.url,
                tabTitle: tab.title,
                bookmarks: bookmarks,
                isTitleSimilar: matcher.isSimilar
            )
        }.value
        if let voted, voted.confidence >= TabFolderVoteScorer.minimumConfidence { return voted }
        return await askModelToChooseFolder(tab: tab, bookmarks: bookmarks)
    }

    /// Fallback: the on-device model picks among the user's existing folders.
    private func askModelToChooseFolder(tab: SyncedTab, bookmarks: [ScoredBookmark]) async -> TabFolderRecommendation? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable else { return nil }
        var seenFolderKeys = Set<String>()
        let folders = bookmarks
            .filter { !$0.folderPath.isEmpty && seenFolderKeys.insert(TabFolderVoteScorer.folderKey($0)).inserted }
            .prefix(40)
        guard !folders.isEmpty else { return nil }
        let folderList = folders.enumerated()
            .map { "\($0.offset + 1). \($0.element.folderPath.joined(separator: " / "))" }
            .joined(separator: "\n")
        let prompt = """
        Pick the best existing bookmark folder for this web page.
        Page title: \(tab.title)
        Page URL: \(tab.url)
        Folders:
        \(folderList)
        Reply ONLY as "<folder number>|<confidence 0.0-1.0>". Use low confidence if no folder fits well.
        """
        do {
            let reply = try await LanguageModelSession(model: .default).respond(to: prompt).content
            guard let choice = TabFolderVoteScorer.parseModelChoice(reply, folderCount: folders.count) else { return nil }
            let folder = Array(folders)[choice.index]
            return TabFolderRecommendation(
                browserName: folder.browserName,
                profileName: folder.profileName,
                folderPath: folder.folderPath,
                confidence: choice.confidence
            )
        } catch {
            logger.warning("Folder choice by model failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        return nil
    }

    /// Only the tab's own Mac: `.addBookmark` is executed there, so the folder
    /// must exist in that Mac's bookmark tree.
    private static func bookmarks(onDevice deviceID: String, state: CachedSyncState) -> [ScoredBookmark] {
        state.bookmarkBlobs.filter { $0.deviceID == deviceID }.flatMap { blob in
            blob.bookmarks.map {
                ScoredBookmark(
                    title: $0.title,
                    url: $0.url,
                    browserName: blob.browserName,
                    profileName: blob.profileName,
                    folderPath: BookmarkTreeBuilder.splitPath($0.folderPath ?? "")
                )
            }
        }
    }
}

/// NLEmbedding sentence similarity with a vector cache per title. Lock-guarded
/// because scoring runs off the main actor.
final class TitleSimilarityMatcher: @unchecked Sendable {
    static let similarityThreshold = 0.80
    private let lock = NSLock()
    private lazy var embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private var vectorsByTitle: [String: [Double]] = [:]

    func isSimilar(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = vector(for: lhs), let right = vector(for: rhs) else { return false }
        return Self.cosine(left, right) >= Self.similarityThreshold
    }

    private func vector(for title: String) -> [Double]? {
        lock.lock(); defer { lock.unlock() }
        if let cached = vectorsByTitle[title] { return cached }
        guard let computed = embedding?.vector(for: title.lowercased()) else { return nil }
        vectorsByTitle[title] = computed
        return computed
    }

    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0, leftNorm = 0.0, rightNorm = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { return 0 }
        return dot / (leftNorm.squareRoot() * rightNorm.squareRoot())
    }
}
