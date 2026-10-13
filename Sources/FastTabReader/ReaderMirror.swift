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

    private struct Stored: Codable, Sendable {
        let id: String
        let urlKey: String
        let payload: Data
    }

    public init(directory: URL, comments: CommentStore? = nil) {
        self.directory = directory
        self.comments = comments ?? Self.commentStore(in: directory)
        byID = Dictionary(Self.loadHighlights(in: directory).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
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
            highlights: mirror
        )
    }

    public func syncedHighlights() -> [SyncedReaderHighlight] {
        byID.values.sorted { $0.id < $1.id }
    }

    public func applyRemote(_ highlight: SyncedReaderHighlight) {
        byID[highlight.id] = highlight
        save()
    }

    public func removeRemote(id: String) {
        guard byID.removeValue(forKey: id) != nil else { return }
        save()
    }

    private func save() {
        let stored = syncedHighlights().map { Stored(id: $0.id, urlKey: $0.urlKey, payload: $0.payload) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(stored).write(to: Self.highlightsURL(in: directory), options: .atomic)
        } catch {
            // Next fetch re-applies; the ledger only advances for what was applied in memory.
        }
    }

    private nonisolated static func highlightsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("highlights.json")
    }
}
