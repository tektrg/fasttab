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

    /// Each highlight of one article paired with its thread: the linked one, else the oldest
    /// unclaimed thread on exactly the same passage. A thread goes to one highlight only, and
    /// a highlight without offsets in its descriptor never matches by anchor (its `from` 0
    /// would collide with every other such highlight).
    public static func assign<H>(
        _ highlights: [H], threads: [CommentThread],
        id: (H) -> String, linkedThreadId: (H) -> String?, serializedRange: (H) -> String, selectedText: (H) -> String
    ) -> [String: CommentThread] {
        var result: [String: CommentThread] = [:]
        var claimed = Set(highlights.compactMap(linkedThreadId))
        for highlight in highlights {
            if let linked = linkedThreadId(highlight), let thread = threads.first(where: { $0.id == linked }) {
                result[id(highlight)] = thread
            }
        }
        for highlight in highlights where linkedThreadId(highlight) == nil && hasOffsets(serializedRange(highlight)) {
            let anchor = self.anchor(serializedRange: serializedRange(highlight), selectedText: selectedText(highlight))
            if let thread = threads.first(where: { thread in
                guard !claimed.contains(thread.id), let other = thread.anchor else { return false }
                return other.from == anchor.from && other.to == anchor.to && other.quote == anchor.quote
            }) {
                claimed.insert(thread.id)
                result[id(highlight)] = thread
            }
        }
        return result
    }

    static func hasOffsets(_ serializedRange: String) -> Bool {
        struct Start: Decodable { let start: Int? }
        return (try? JSONDecoder().decode(Start.self, from: Data(serializedRange.utf8)))?.start.map { $0 >= 0 } ?? false
    }
}
