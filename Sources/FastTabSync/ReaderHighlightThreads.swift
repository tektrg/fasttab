import Foundation
import IndieComments

/// Which comment thread belongs to a reader highlight, the same answer on the phone and the
/// Mac. The phone records the link on the highlight (`commentThreadId`) when it opens a
/// thread; a thread opened elsewhere (an agent on the Mac) can't edit the highlight, so it
/// is found by its anchor: same passage, same offsets.
public enum ReaderHighlightThreads {
    /// The highlight's passage as a shared anchor, from the reader's range descriptor
    /// (UTF-16 offsets into the article body, plus 32 characters of context each side).
    public static func anchor(serializedRange: String, selectedText: String) -> TextAnchor {
        struct Descriptor: Decodable {
            let text: String?
            let start: Int?
            let len: Int?
            let cb: String?
            let ca: String?
        }
        let descriptor = try? JSONDecoder().decode(Descriptor.self, from: Data(serializedRange.utf8))
        let quote = descriptor?.text ?? selectedText
        let length = descriptor?.len ?? quote.utf16.count
        let start = max(0, descriptor?.start ?? 0)
        return TextAnchor(
            from: start, to: start + max(1, length), quote: quote,
            contextBefore: descriptor?.cb.flatMap { $0.isEmpty ? nil : $0 },
            contextAfter: descriptor?.ca.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The highlight's thread among its article's live threads: the linked one, else the
    /// oldest whose anchor sits on the same passage.
    public static func thread(
        linkedThreadId: String?, anchor: TextAnchor, in threads: [CommentThread]
    ) -> CommentThread? {
        if let linkedThreadId, let linked = threads.first(where: { $0.id == linkedThreadId }) {
            return linked
        }
        return threads.first { thread in
            guard let other = thread.anchor else { return false }
            return other.from == anchor.from && other.to == anchor.to && other.quote == anchor.quote
        }
    }
}
