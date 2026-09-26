import Foundation
import CryptoKit
import UIKit

/// Persistent, two-tier cache (in-memory + disk) for extracted `ReaderArticle` objects.
/// Ensures reopening previously extracted links renders instantly without re-processing via Readability.js.
/// Capped at 50 most recently accessed articles with LRU disk eviction.
@MainActor
public final class ReaderArticleCache: ObservableObject {
    public static let shared = ReaderArticleCache()

    private static let maxEntries = 50
    private static let indexDefaultsKey = "FastTabMobile.readerArticleCacheIndexV1"
    /// Set once X posts cached before captioned-Article detection have been dropped.
    private static let xPostsPurgedDefaultsKey = "FastTabMobile.readerArticleCacheXPurgedV1"

    // Tier 1: In-memory dictionary for sub-millisecond access
    private var memoryCache: [String: ReaderArticle] = [:]

    // Index tracking LRU access timestamps: [canonicalURL: lastAccessedAt]
    private var accessIndex: [String: Date] = [:]

    private let cacheDirectoryURL: URL
    private let fileManager: FileManager
    private var memoryWarningObserver: NSObjectProtocol?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            self.cacheDirectoryURL = cachesDir.appendingPathComponent("FastTabReaderArticles", isDirectory: true)
        } else {
            self.cacheDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FastTabReaderArticles", isDirectory: true)
        }

        try? fileManager.createDirectory(at: self.cacheDirectoryURL, withIntermediateDirectories: true)
        loadIndex()
        purgeStaleXPostsOnce()

        // Evict in-memory tier under system memory pressure (disk tier remains intact)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearMemoryTier()
        }
    }

    deinit {
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Evicts Tier 1 (RAM) cache while preserving persistent Tier 2 (disk) storage.
    public func clearMemoryTier() {
        memoryCache.removeAll()
    }

    /// Retrieves a cached article for the given URL, if available.
    /// Checks in-memory cache first, then falls back to disk. Updates last access timestamp.
    public func article(for url: URL) -> ReaderArticle? {
        let key = canonical(url)

        // Check in-memory first
        if let cached = memoryCache[key] {
            recordAccess(key: key)
            return cached
        }

        // Check on disk
        let fileURL = diskFileURL(for: key)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL),
              let article = try? JSONDecoder().decode(ReaderArticle.self, from: data) else {
            // Corrupted or unreadable disk cache entry — remove it and clean index
            try? fileManager.removeItem(at: fileURL)
            accessIndex.removeValue(forKey: key)
            saveIndex()
            return nil
        }

        // Promote to memory cache
        memoryCache[key] = article
        recordAccess(key: key)
        return article
    }

    /// Checks whether an article is already cached for the given URL without decoding full disk content if possible.
    public func hasCachedArticle(for url: URL) -> Bool {
        let key = canonical(url)
        if memoryCache[key] != nil { return true }
        return fileManager.fileExists(atPath: diskFileURL(for: key).path)
    }

    /// Saves an extracted article to both in-memory and disk cache.
    public func save(_ article: ReaderArticle) {
        guard !article.isEmpty else { return }
        let key = canonical(article.url)

        memoryCache[key] = article
        recordAccess(key: key)

        // Write to disk
        if let data = try? JSONEncoder().encode(article) {
            let fileURL = diskFileURL(for: key)
            try? data.write(to: fileURL, options: .atomic)
        }

        evictIfNeeded()
        saveIndex()
    }

    /// Removes a cached article for the given URL from both memory and disk.
    public func remove(for url: URL) {
        let key = canonical(url)
        memoryCache.removeValue(forKey: key)
        accessIndex.removeValue(forKey: key)
        let fileURL = diskFileURL(for: key)
        try? fileManager.removeItem(at: fileURL)
        saveIndex()
    }

    /// Clears all cached articles from both memory and disk.
    public func clear() {
        memoryCache.removeAll()
        accessIndex.removeAll()
        try? fileManager.removeItem(at: cacheDirectoryURL)
        try? fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
        saveIndex()
    }

    // MARK: - Internal Helpers

    private func canonical(_ url: URL) -> String {
        url.readerCanonicalKey
    }

    private func diskFileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8))
        let filename = hash.compactMap { String(format: "%02x", $0) }.joined() + ".json"
        return cacheDirectoryURL.appendingPathComponent(filename)
    }

    private func recordAccess(key: String) {
        accessIndex[key] = Date()
        saveIndex()
    }

    private func evictIfNeeded() {
        guard accessIndex.count > Self.maxEntries else { return }

        // Sort by last accessed date ascending (oldest first)
        let sorted = accessIndex.sorted { $0.value < $1.value }
        let toRemoveCount = accessIndex.count - Self.maxEntries
        let keysToRemove = sorted.prefix(toRemoveCount).map { $0.key }

        for key in keysToRemove {
            memoryCache.removeValue(forKey: key)
            accessIndex.removeValue(forKey: key)
            let fileURL = diskFileURL(for: key)
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// X Articles posted with a caption used to be cached as caption + cover image, no body.
    /// Drop every cached X post once so they re-extract with the Article check.
    private func purgeStaleXPostsOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.xPostsPurgedDefaultsKey) else { return }
        for key in accessIndex.keys {
            guard let url = URL(string: key), ReaderExtractor.isTwitterURL(url) else { continue }
            accessIndex.removeValue(forKey: key)
            try? fileManager.removeItem(at: diskFileURL(for: key))
        }
        saveIndex()
        UserDefaults.standard.set(true, forKey: Self.xPostsPurgedDefaultsKey)
    }

    private func loadIndex() {
        guard let data = UserDefaults.standard.data(forKey: Self.indexDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return
        }
        accessIndex = decoded
    }

    private func saveIndex() {
        guard let encoded = try? JSONEncoder().encode(accessIndex) else { return }
        UserDefaults.standard.set(encoded, forKey: Self.indexDefaultsKey)
    }
}
