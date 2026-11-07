import Foundation
import CryptoKit

/// The phone's copy of every Mac's `SyncedFavicons`, kept in its own small files
/// (never inside the cached sync state, which is rewritten on every sync tick).
///
/// One file per Mac, named by a hash of the record name: hosts and device ids come
/// from synced data and must never become path components. Loaded lazily, merged
/// across Macs (most recently updated snapshot wins a shared host). Thread-safe.
public final class SyncedFaviconStore: @unchecked Sendable {
    private struct Snapshot: Codable {
        let recordName: String
        let favicons: [String: Data]
        let deviceID: String
        let updatedAt: Date
    }

    private let directory: URL
    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]
    private var loaded = false

    public init(directory: URL) {
        self.directory = directory
    }

    /// Records a Mac's snapshot unless a newer one for that Mac is already held.
    /// Returns whether the visible icon set changed (callers refresh views only then).
    @discardableResult
    public func apply(_ favicons: SyncedFavicons) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        if let existing = snapshots[favicons.id] {
            if existing.updatedAt > favicons.updatedAt { return false }
            if existing.favicons == favicons.icons { return false }
        }
        let snapshot = Snapshot(
            recordName: favicons.id,
            favicons: favicons.icons,
            deviceID: favicons.deviceID,
            updatedAt: favicons.updatedAt
        )
        snapshots[favicons.id] = snapshot
        write(snapshot)
        return true
    }

    /// A Mac's `SyncedFavicons` record was deleted on the server. Returns whether
    /// anything was held for it (most state-zone deletions are tabs, not favicons).
    @discardableResult
    public func remove(recordName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard snapshots.removeValue(forKey: recordName) != nil else { return false }
        try? FileManager.default.removeItem(at: fileURL(forRecordName: recordName))
        return true
    }

    /// PNG bytes for a host from the freshest Mac that has one.
    public func iconData(forHost host: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        for snapshot in snapshots.values.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let view = SyncedFavicons(deviceID: snapshot.deviceID, icons: snapshot.favicons, updatedAt: snapshot.updatedAt)
            if let data = view.icon(forHost: host) { return data }
        }
        return nil
    }

    // MARK: - Disk

    private func fileURL(forRecordName name: String) -> URL {
        let hash = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hash).favicons")
    }

    private func write(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(snapshot).write(to: fileURL(forRecordName: snapshot.recordName), options: .atomic)
        } catch {
            // Memory-only until the next successful write; icons are re-synced anyway.
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.pathExtension == "favicons" {
            if let data = try? Data(contentsOf: url),
               let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) {
                snapshots[snapshot.recordName] = snapshot
            } else {
                try? FileManager.default.removeItem(at: url)   // corrupt: the Mac re-sends it
            }
        }
    }
}
