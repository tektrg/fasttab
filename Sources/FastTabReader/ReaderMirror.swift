import FastTabSync
import Foundation
import IndieComments

/// The Mac's copy of the phone's reader highlights and their comment threads, kept current
/// by reader sync (`ReaderSyncBridge`). Lives in `<support>/Reader/`:
/// `highlights.json` (each highlight's phone payload, as synced) and `comments/` (one MDLY-
/// format comment log per article). Agent tools read and write here; writes sync back.
@MainActor
public final class ReaderMirror: ReaderHighlightSyncStore {
    public let directory: URL
    public let comments: CommentStore
    private var byID: [String: SyncedReaderHighlight]
    /// Highlights made on this Mac (imported from the web reader): the only ones it sends to
    /// CloudKit. Everything else is the phone's, mirrored read-only.
    private var ownIDs: Set<String>

    private struct Stored: Codable, Sendable {
        let id: String
        let urlKey: String
        let payload: Data
    }

    public init(directory: URL, comments: CommentStore? = nil) {
        self.directory = directory
        self.comments = comments ?? Self.commentStore(in: directory)
        byID = Dictionary(Self.loadHighlights(in: directory).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        ownIDs = Set((try? JSONDecoder().decode([String].self, from: Data(contentsOf: Self.ownIDsURL(in: directory)))) ?? [])
    }

    /// True for a highlight this Mac created (see `ownIDs`).
    public func isOwn(_ id: String) -> Bool { ownIDs.contains(id) }

    /// Adds a highlight made on this Mac; the bridge sends it on its next pending pass.
    /// An id already present is left alone (re-imports are no-ops). False when not added.
    @discardableResult
    public func addOwn(_ highlight: SyncedReaderHighlight) -> Bool {
        guard byID[highlight.id] == nil else { return false }
        byID[highlight.id] = highlight
        ownIDs.insert(highlight.id)
        save()
        return true
    }

    /// The mirror folder in the app's support directory, shared with the MCP helper.
    public static func directory(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Reader", isDirectory: true)
    }

    public nonisolated static func commentStore(in directory: URL) -> CommentStore {
        CommentStore(log: CommentLog(directory: directory.appendingPathComponent("comments", isDirectory: true)))
    }

    /// The highlights as last written (any process may read; only the app writes).
    public nonisolated static func loadHighlights(in directory: URL) -> [SyncedReaderHighlight] {
        let stored = (try? JSONDecoder().decode([Stored].self, from: Data(contentsOf: highlightsURL(in: directory)))) ?? []
        return stored.map { SyncedReaderHighlight(id: $0.id, urlKey: $0.urlKey, payload: $0.payload) }
    }

    /// The sync bridge over this mirror; its ledger sits beside the mirror.
    public static func makeBridge(supportDirectory: URL) -> ReaderSyncBridge {
        let mirror = ReaderMirror(directory: directory(supportDirectory: supportDirectory))
        return ReaderSyncBridge(
            ledgerURL: mirror.directory.appendingPathComponent("sync_ledger.json"),
            comments: mirror.comments,
            highlights: mirror,
            sendsHighlights: false,
            sendsOwnHighlight: { [weak mirror] id in mirror?.isOwn(id) ?? false }
        )
    }

    public func syncedHighlights() -> [SyncedReaderHighlight] {
        byID.values.sorted { $0.id < $1.id }
    }

    public func applyRemote(_ highlight: SyncedReaderHighlight) -> Bool {
        byID[highlight.id] = highlight
        save()
        return true
    }

    public func removeRemote(id: String) {
        guard byID.removeValue(forKey: id) != nil else { return }
        ownIDs.remove(id)
        save()
    }

    private func save() {
        let stored = syncedHighlights().map { Stored(id: $0.id, urlKey: $0.urlKey, payload: $0.payload) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: Self.highlightsURL(in: directory), options: .atomic)
            try JSONEncoder().encode(ownIDs.sorted()).write(to: Self.ownIDsURL(in: directory), options: .atomic)
        } catch {
            // Next fetch re-applies; the ledger only advances for what was applied in memory.
        }
    }

    private nonisolated static func ownIDsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("own_highlight_ids.json")
    }

    private nonisolated static func highlightsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("highlights.json")
    }
}
