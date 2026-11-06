import Foundation
import OSLog

/// Remembered AI-filter verdicts, so a page is classified once per prompt.
///
/// Key = hash(normalized prompt) : hash(page identity) : hash(title). Editing
/// a view's prompt changes the prompt hash, so everything is classified
/// afresh; a retitled tab gets a new key and is re-checked. Only real
/// verdicts are stored — items the model failed on stay uncached ("unknown")
/// and are retried on the next run.
///
/// Persisted as JSON in Application Support (`FastTab/custom-view-ai-cache.json`),
/// capped at `capacity` entries; past it, the least recently used are evicted
/// down to 90%. Entries of prompts no view uses any more are dropped by
/// `prune(keepingPromptHashes:)`.
///
/// Saving: changes are coalesced (one write `saveDelay` after the last one),
/// and the JSON is encoded and written atomically on a serial background
/// queue — never on the main thread. `flush()` (app termination) writes any
/// pending change synchronously.
@MainActor
final class CustomViewSemanticCache {
    static var shared: CustomViewSemanticCache {
        if let loaded = sharedIfLoaded { return loaded }
        let cache = CustomViewSemanticCache(fileURL: defaultFileURL)
        sharedIfLoaded = cache
        return cache
    }

    /// Set once something used the shared cache (so quitting never loads a
    /// 20k-entry file just to flush it).
    private(set) static var sharedIfLoaded: CustomViewSemanticCache?

    static let defaultCapacity = 20_000

    struct Entry: Codable, Equatable, Sendable {
        /// Matches the prompt.
        var m: Bool
        /// Last used (seconds since 1970), for LRU eviction.
        var t: Double
    }

    private struct FileContents: Codable, Sendable {
        var version: Int
        var entries: [String: Entry]
    }

    private static let fileVersion = 1

    private(set) var entries: [String: Entry]
    let capacity: Int
    private let fileURL: URL?
    private let now: () -> Date
    private let saveDelay: TimeInterval
    /// Called on the write queue after each file write (tests).
    private let onWrite: (@Sendable () -> Void)?
    private var saveTask: Task<Void, Never>?
    /// Entries changed since the last write was handed to the queue.
    private var isDirty = false
    /// Serial: writes land in the order they were made.
    private let writeQueue = DispatchQueue(label: "com.trungluong.FastTab.CustomViewAICache", qos: .utility)
    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "CustomViewAI")

    /// `fileURL` nil = memory only (tests).
    init(
        fileURL: URL?,
        capacity: Int = CustomViewSemanticCache.defaultCapacity,
        now: @escaping () -> Date = Date.init,
        saveDelay: TimeInterval = 1.5,
        onWrite: (@Sendable () -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
        self.now = now
        self.saveDelay = max(0, saveDelay)
        self.onWrite = onWrite
        entries = Self.load(from: fileURL)
    }

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FastTab", isDirectory: true)
            .appendingPathComponent("custom-view-ai-cache.json")
    }

    // MARK: Keys

    /// Lowercased, whitespace-collapsed — "Articles  to read" and
    /// "articles to read" share verdicts.
    static func normalizedPrompt(_ prompt: String) -> String {
        prompt.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    static func promptHash(_ prompt: String) -> String {
        hex(fnv1a64(normalizedPrompt(prompt)))
    }

    static func key(promptHash: String, item: CustomViewItem) -> String {
        let page = CustomViewFilter.pageKey(forURL: item.result.url)
        let title = strippingLeadingCountBadge(item.result.title).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(promptHash):\(hex(fnv1a64(page))):\(hex(fnv1a64(title)))"
    }

    /// Stable across launches (unlike `hashValue`).
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func hex(_ value: UInt64) -> String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 16 - s.count)) + s
    }

    // MARK: Read / write

    /// The stored verdict (and marks it recently used), nil when unknown.
    func verdict(forKey key: String) -> Bool? {
        guard var entry = entries[key] else { return nil }
        entry.t = now().timeIntervalSince1970
        entries[key] = entry
        return entry.m
    }

    func store(_ matches: [String: Bool]) {
        guard !matches.isEmpty else { return }
        let stamp = now().timeIntervalSince1970
        for (key, match) in matches { entries[key] = Entry(m: match, t: stamp) }
        evictIfNeeded()
        scheduleSave()
    }

    /// Drops verdicts of prompts no view uses any more (deleted views,
    /// edited prompts).
    func prune(keepingPromptHashes keep: Set<String>) {
        let before = entries.count
        entries = entries.filter { key, _ in
            guard let colon = key.firstIndex(of: ":") else { return false }
            return keep.contains(String(key[..<colon]))
        }
        if entries.count != before { scheduleSave() }
    }

    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        let target = max(1, capacity * 9 / 10)
        let drop = entries.count - target
        let oldest = entries.sorted { $0.value.t < $1.value.t }.prefix(drop).map(\.key)
        for key in oldest { entries.removeValue(forKey: key) }
    }

    // MARK: Persistence

    /// Coalesces writes: one save `saveDelay` after the last change.
    private func scheduleSave() {
        guard fileURL != nil else { return }
        isDirty = true
        saveTask?.cancel()
        let delay = UInt64(saveDelay * 1_000_000_000)
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.enqueueWrite(wait: false)
        }
    }

    /// Writes any pending change now and waits for it (app termination).
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        enqueueWrite(wait: true)
    }

    /// Hands a snapshot of `entries` (a copy-on-write value — cheap here) to
    /// the write queue, which encodes and writes it atomically.
    private func enqueueWrite(wait: Bool) {
        guard isDirty, let fileURL else { return }
        isDirty = false
        let contents = FileContents(version: Self.fileVersion, entries: entries)
        let logger = self.logger
        let onWrite = self.onWrite
        let work: @Sendable () -> Void = {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(contents).write(to: fileURL, options: .atomic)
            } catch {
                logger.error("AI filter cache save failed: \(error.localizedDescription, privacy: .public)")
            }
            onWrite?()
        }
        if wait { writeQueue.sync(execute: work) } else { writeQueue.async(execute: work) }
    }

    private static func load(from fileURL: URL?) -> [String: Entry] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let contents = try? JSONDecoder().decode(FileContents.self, from: data),
              contents.version == fileVersion else { return [:] }
        return contents.entries
    }
}
