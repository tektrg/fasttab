import FastTabSync
import Foundation
import IndieComments

/// The Mac's copy of the phone's reader highlights and their comment threads, kept current
/// by reader sync (`ReaderSyncBridge`). Lives in `<support>/Reader/`:
/// `highlights.json` (each highlight's phone payload, as synced) and `comments/` (one MDLY-
/// format comment log per article). Agent tools read and write here; writes sync back.
@MainActor
final class ReaderMirror: ReaderHighlightSyncStore {
    let directory: URL
    let comments: CommentStore
    private var byID: [String: SyncedReaderHighlight]

    private struct Stored: Codable {
        let id: String
        let urlKey: String
        let payload: Data
    }

    init(directory: URL) {
        self.directory = directory
        comments = CommentStore(log: CommentLog(directory: directory.appendingPathComponent("comments", isDirectory: true)))
        let stored = (try? JSONDecoder().decode([Stored].self, from: Data(contentsOf: Self.highlightsURL(in: directory)))) ?? []
        byID = Dictionary(stored.map { ($0.id, SyncedReaderHighlight(id: $0.id, urlKey: $0.urlKey, payload: $0.payload)) },
                          uniquingKeysWith: { $1 })
    }

    /// The sync bridge over this mirror; its ledger sits beside the mirror.
    static func makeBridge(supportDirectory: URL) -> ReaderSyncBridge {
        let mirror = ReaderMirror(directory: supportDirectory.appendingPathComponent("Reader", isDirectory: true))
        return ReaderSyncBridge(
            ledgerURL: mirror.directory.appendingPathComponent("sync_ledger.json"),
            comments: mirror.comments,
            highlights: mirror
        )
    }

    func syncedHighlights() -> [SyncedReaderHighlight] {
        byID.values.sorted { $0.id < $1.id }
    }

    func applyRemote(_ highlight: SyncedReaderHighlight) {
        byID[highlight.id] = highlight
        save()
    }

    func removeRemote(id: String) {
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

    private static func highlightsURL(in directory: URL) -> URL {
        directory.appendingPathComponent("highlights.json")
    }
}
