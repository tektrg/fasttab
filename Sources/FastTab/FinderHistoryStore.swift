import Foundation
import OSLog

/// One persisted Finder-history entry. Keyed by absolute path in the store.
struct FinderHistoryEntry: Codable, Equatable, Sendable {
    var path: String
    var basename: String
    var parentDir: String
    var lastVisit: Date
}

/// Owns the on-disk Finder-history index: every Finder window we observe via
/// `FinderBackend.fetchLiveTabs` is upserted here, then surfaced through the
/// existing `@History` chip path. Browsers ship their own history DB; Finder
/// doesn't, so we maintain one.
///
/// Thread-safety: read/written from both `Task.detached` (fetch path) and the
/// main actor (delete via swipe). One `NSLock` is sufficient — operations are
/// tiny dict ops, not contended enough to warrant an actor here.
final class FinderHistoryStore: @unchecked Sendable {
    static let shared = FinderHistoryStore()

    private static let defaultsKey = "FastTab.finderHistoryV1"
    /// 90 days, matching the design choice for Finder-history retention.
    /// Browsers manage their own DBs; we own this one, so we cap it.
    private static let evictionMaxAge: TimeInterval = 90 * 24 * 60 * 60
    /// Throttle UserDefaults writes. In-memory state is always current.
    private static let persistInterval: TimeInterval = 5

    private let logger = Logger(subsystem: "com.trungluong.FastTab", category: "FinderHistoryStore")
    private let lock = NSLock()
    private var entries: [String: FinderHistoryEntry]
    private var lastPersistAt: Date = .distantPast

    init() {
        self.entries = Self.load()
        logger.info("FinderHistoryStore init. entries=\(self.entries.count)")
    }

    private static func load() -> [String: FinderHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: FinderHistoryEntry].self, from: data) else {
            return [:]
        }
        let now = Date()
        return decoded.filter { now.timeIntervalSince($0.value.lastVisit) < evictionMaxAge }
    }

    /// Caller must hold `lock`.
    private func persistLocked(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.lastVisit) < Self.evictionMaxAge }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        lastPersistAt = now
    }

    /// Upsert an observation. Title/parent derived from the path so callers
    /// don't need to pass them. Throttled persistence — `flush()` for hard sync.
    func record(path: String, at timestamp: Date = Date()) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let ns = trimmed as NSString
        let basename = ns.lastPathComponent
        let parentDir = ns.deletingLastPathComponent

        lock.lock()
        defer { lock.unlock() }
        var entry = entries[trimmed] ?? FinderHistoryEntry(
            path: trimmed,
            basename: basename,
            parentDir: parentDir,
            lastVisit: timestamp
        )
        entry.lastVisit = timestamp
        entry.basename = basename
        entry.parentDir = parentDir
        entries[trimmed] = entry

        if timestamp.timeIntervalSince(lastPersistAt) >= Self.persistInterval {
            persistLocked(now: timestamp)
        }
    }

    /// Force-persist immediately. Use after user-driven mutations where losing
    /// the update on crash would be surprising (delete).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        persistLocked(now: Date())
    }

    func remove(path: String) {
        lock.lock()
        defer { lock.unlock() }
        if entries.removeValue(forKey: path) != nil {
            persistLocked(now: Date())
        }
    }

    /// Snapshot for sort/filter. O(n) copy; n is bounded by 90-day eviction.
    func snapshot() -> [FinderHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.values)
    }
}
