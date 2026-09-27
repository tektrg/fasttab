import Foundation
import FastTabSync
import IndieMetrics

/// Decides the topic of each read article at chart time, so topics follow the user's bookmarks
/// as they change rather than being frozen into the log. First match wins:
///
/// 1. the folder the article is bookmarked in (any Mac, any browser);
/// 2. the existing folder `TabFolderRecommender` infers for it (on-device vote/model, cached);
/// 3. its host;
/// 4. `uncategorized`.
@MainActor
final class ReadingTopicResolver: ObservableObject {
    static let shared = ReadingTopicResolver(defaults: .standard)
    static let uncategorized = "Uncategorized"
    private static let inferredDefaultsKey = "FastTabMobile.readingTopicInferredFolderV1"
    /// Articles remembered in the inference cache.
    private static let maxInferredEntries = 3_000

    /// article key -> inferred folder name; "" means "asked, nothing confident". Published so
    /// charts regroup when a background inference lands.
    @Published private(set) var inferredFolderByArticle: [String: String]
    private var inFlightArticles = Set<String>()
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.inferredFolderByArticle = defaults.dictionary(forKey: Self.inferredDefaultsKey) as? [String: String] ?? [:]
    }

    /// The fallback order, pure. Blank names count as missing.
    nonisolated static func topic(bookmarkFolder: String?, inferredFolder: String?, host: String?) -> String {
        for candidate in [bookmarkFolder, inferredFolder, host] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return uncategorized
    }

    /// Topic per article subject in `events`. Starts background inference for articles with no
    /// bookmark folder and no cached answer; their topic updates when it lands.
    func topicsByArticle(for events: [MetricEvent], bookmarkBlobs: [SyncedBookmarkBlob]) -> [String: String] {
        let bookmarkFolderByArticle = Self.bookmarkFolderByArticle(in: bookmarkBlobs)
        var topics: [String: String] = [:]
        var needsInference: [MetricEvent] = []
        for event in events where topics[event.subject] == nil {
            let bookmarkFolder = bookmarkFolderByArticle[event.subject]
            let inferred = inferredFolderByArticle[event.subject]
            if bookmarkFolder == nil, inferred == nil { needsInference.append(event) }
            topics[event.subject] = Self.topic(
                bookmarkFolder: bookmarkFolder,
                inferredFolder: inferred,
                host: event.labels[ReadingMetric.hostLabel]
            )
        }
        inferFolders(for: needsInference, bookmarkBlobs: bookmarkBlobs)
        return topics
    }

    /// Bookmarked article key -> the name of its innermost folder (top-level bookmarks have none).
    nonisolated static func bookmarkFolderByArticle(in blobs: [SyncedBookmarkBlob]) -> [String: String] {
        var folders: [String: String] = [:]
        for blob in blobs {
            for bookmark in blob.bookmarks {
                guard let url = URL(string: bookmark.url),
                      let folderName = BookmarkTreeBuilder.splitPath(bookmark.folderPath ?? "").last else { continue }
                folders[url.readerCanonicalKey] = folderName
            }
        }
        return folders
    }

    private func inferFolders(for events: [MetricEvent], bookmarkBlobs: [SyncedBookmarkBlob]) {
        let pending = events.filter { !inFlightArticles.contains($0.subject) }
        guard !pending.isEmpty, !bookmarkBlobs.isEmpty else { return }
        pending.forEach { inFlightArticles.insert($0.subject) }
        let bookmarks = TabFolderRecommender.scoredBookmarks(in: bookmarkBlobs)
        Task { [weak self] in
            for event in pending {
                let title = event.labels[ReadingMetric.titleLabel] ?? ""
                let folder = await TabFolderRecommender.shared
                    .recommendFolder(title: title, url: event.subject, bookmarks: bookmarks)?.folderPath.last
                self?.storeInferredFolder(folder ?? "", forArticle: event.subject)
            }
        }
    }

    private func storeInferredFolder(_ folderName: String, forArticle articleKey: String) {
        inFlightArticles.remove(articleKey)
        inferredFolderByArticle[articleKey] = folderName
        // Past the cap, start over rather than track recency: re-asking is only a little work.
        if inferredFolderByArticle.count > Self.maxInferredEntries {
            inferredFolderByArticle = [articleKey: folderName]
        }
        defaults.set(inferredFolderByArticle, forKey: Self.inferredDefaultsKey)
    }
}
