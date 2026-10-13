import FastTabSync
import Foundation
import IndieComments

/// Comment threads on reader highlights, in the portfolio's shared anchored-thread model
/// (IndieLibKit `IndieComments`, MDLY's format). One log per article; a highlight points at
/// its thread through `ReaderHighlight.commentThreadId`, set when its first comment is written.
/// Local only for now, like the highlights themselves.
@MainActor
public final class ReaderCommentThreads: ObservableObject {
    public static let shared = ReaderCommentThreads(directory: defaultDirectory)

    /// The person using the app. Agents write as `.agent` through MCP (later step).
    public static let me = CommentAuthor(kind: .human, id: "me", label: "You")

    /// Live threads by highlight id, for the highlights `load` has seen.
    @Published public private(set) var threadsByHighlightID: [String: CommentThread] = [:]

    /// The one store for this folder: reader sync writes incoming events through it too, so
    /// every append is serialized.
    let store: CommentStore
    /// Bumped on every write; `changedAt` records it per highlight so a slower `load` never
    /// overwrites a fresher thread.
    private var changeCount = 0
    private var changedAt: [String: Int] = [:]
    private let highlightStore: () -> ReaderHighlightStore

    /// Records the thread on its highlight; false when the highlight is gone.
    private let linkThread: (_ threadId: String, _ highlight: ReaderHighlight) -> Bool

    /// Tests pass `linkThread` so nothing is written to the real highlight store.
    init(
        directory: URL,
        highlightStore: @escaping () -> ReaderHighlightStore = { .shared },
        linkThread: ((String, ReaderHighlight) -> Bool)? = nil
    ) {
        store = CommentStore(log: CommentLog(directory: directory))
        self.highlightStore = highlightStore
        self.linkThread = linkThread ?? { threadId, highlight in
            highlightStore().setCommentThreadId(threadId, for: highlight.id, urlKey: highlight.urlKey)
        }
    }

    public func thread(for highlight: ReaderHighlight) -> CommentThread? {
        threadsByHighlightID[highlight.id]
    }

    // Threads are read with no article text: the reader places highlights itself, so the
    // anchor's resolution against the page is not needed here.

    /// Reads the threads of every commented highlight in `highlights` (small local files).
    public func load(_ highlights: [ReaderHighlight]) {
        let commented = highlights.filter { $0.commentThreadId != nil }
        let startedAt = changeCount
        Task {
            var loaded: [String: CommentThread] = [:]
            for (urlKey, group) in Dictionary(grouping: commented, by: \.urlKey) {
                let threads = (try? await store.threads(docId: Self.docId(urlKey: urlKey), text: "")) ?? []
                for highlight in group {
                    if let thread = threads.first(where: { $0.id == highlight.commentThreadId }) {
                        loaded[highlight.id] = thread
                    }
                }
            }
            // A post/resolve/delete that landed while this read ran is newer: keep it.
            let ids = Set(commented.map(\.id)).filter { (changedAt[$0] ?? 0) <= startedAt }
            threadsByHighlightID = threadsByHighlightID.filter { !ids.contains($0.key) }
                .merging(loaded.filter { ids.contains($0.key) }) { $1 }
        }
    }

    /// Writes a comment: opens the highlight's thread on the first one, replies after that
    /// (a reply on a resolved thread reopens it).
    public func post(_ text: String, on highlight: ReaderHighlight) async throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let docId = Self.docId(urlKey: highlight.urlKey)
        if let threadId = currentThreadId(of: highlight) {
            try await store.reply(docId: docId, threadId: threadId, author: Self.me, text: body)
            await refresh(highlight, threadId: threadId)
        } else {
            let threadId = try await store.openThread(
                docId: docId, author: Self.me, anchor: Self.anchor(for: highlight), text: body)
            guard linkThread(threadId, highlight) else {
                // Deleted while the thread was being written: don't leave it behind.
                _ = try? await store.delete(docId: docId, threadId: threadId, author: Self.me)
                return
            }
            await refresh(highlight, threadId: threadId)
        }
    }

    public func setResolved(_ resolved: Bool, on highlight: ReaderHighlight) async throws {
        guard let threadId = currentThreadId(of: highlight) else { return }
        let docId = Self.docId(urlKey: highlight.urlKey)
        if resolved {
            try await store.resolve(docId: docId, threadId: threadId, author: Self.me)
        } else {
            try await store.reopen(docId: docId, threadId: threadId, author: Self.me)
        }
        await refresh(highlight, threadId: threadId)
    }

    /// Comments arrived from another device: re-read every commented highlight's thread.
    func reloadAfterSync() {
        load(highlightStore().allHighlightsNewestFirst())
    }

    /// Tombstones the threads of highlights being deleted.
    func deleteThreads(of highlights: [ReaderHighlight]) async {
        for highlight in highlights {
            guard let threadId = currentThreadId(of: highlight) else { continue }
            _ = try? await store.delete(docId: Self.docId(urlKey: highlight.urlKey), threadId: threadId, author: Self.me)
            markChanged(highlight.id)
            threadsByHighlightID[highlight.id] = nil
        }
    }

    // MARK: - Mapping

    /// The log name for an article: its canonical URL hashed, since URLs are not file names.
    nonisolated static func docId(urlKey: String) -> String {
        ReaderCommentDocID.forArticle(urlKey: urlKey)
    }

    /// The highlight's passage as a shared anchor: offsets and context from the reader's
    /// range descriptor (UTF-16 offsets into the article body, as JavaScript counts).
    nonisolated static func anchor(for highlight: ReaderHighlight) -> TextAnchor {
        struct Descriptor: Decodable {
            let text: String?
            let start: Int?
            let len: Int?
            let cb: String?
            let ca: String?
        }
        let descriptor = try? JSONDecoder().decode(Descriptor.self, from: Data(highlight.serializedRange.utf8))
        let quote = descriptor?.text ?? highlight.selectedText
        let length = descriptor?.len ?? quote.utf16.count
        let start = max(0, descriptor?.start ?? 0)
        return TextAnchor(
            from: start, to: start + max(1, length), quote: quote,
            contextBefore: descriptor?.cb.flatMap { $0.isEmpty ? nil : $0 },
            contextAfter: descriptor?.ca.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Private

    /// The thread already loaded, else the stored link read fresh: the caller's copy of the
    /// highlight may predate its first comment.
    private func currentThreadId(of highlight: ReaderHighlight) -> String? {
        threadsByHighlightID[highlight.id]?.id
            ?? highlightStore().highlight(id: highlight.id, urlKey: highlight.urlKey)?.commentThreadId
            ?? highlight.commentThreadId
    }

    private func refresh(_ highlight: ReaderHighlight, threadId: String) async {
        // A failed read keeps what is shown rather than blanking it.
        guard let thread = try? await store.thread(id: threadId, docId: Self.docId(urlKey: highlight.urlKey), text: "")
        else { return }
        markChanged(highlight.id)
        threadsByHighlightID[highlight.id] = thread.state == .deleted ? nil : thread
    }

    /// Called after every local write, which reader sync then sends.
    private func markChanged(_ highlightID: String) {
        changeCount += 1
        changedAt[highlightID] = changeCount
        NotificationCenter.default.post(name: .readerDataDidChangeLocally, object: nil)
    }

    private static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ReaderComments", isDirectory: true)
    }
}
